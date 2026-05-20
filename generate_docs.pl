#!/usr/bin/env perl
use strict;
use warnings;
use File::Find;
use JSON::PP;

# Determine directories to scan (CLI arguments or defaults)
my @directories = @ARGV ? @ARGV : ('cappuccino/AppKit', 'cappuccino/Foundation');

# Keep only existing directories
my @valid_dirs = grep { -d $_ } @directories;
unless (@valid_dirs) {
    warn "Error: Directories not found.\nPlease run from the root of the cappuccino repository or provide valid paths.\n";
    print "[]\n";
    exit 1;
}

my @files;
find(sub {
    push @files, $File::Find::name if -f $_ && /\.j$/;
}, @valid_dirs);

my @all_classes;

foreach my $file (@files) {
    my $class_data = parse_file($file);
    push @all_classes, $class_data if $class_data;
}

# Output formatted JSON
my $json = JSON::PP->new->utf8->pretty->canonical->encode(\@all_classes);
print $json;

# ----------------------------------------------------------------------
# Parser implementation
# ----------------------------------------------------------------------
sub parse_file {
    my ($filepath) = @_;
    open my $fh, '<', $filepath or return;

    my $class_name = "";
    my $superclass = "";
    my $class_decl = "";
    my $class_abstract = "";
    my $class_discussion = "";
    
    my @topics;
    my $current_topic = { title => "General", symbols => [] };
    
    my @doc_buffer;
    my $state = 'search';
    my $method_str = "";
    
    my $typedef_name = "";
    my $typedef_decl = "";
    my @typedef_vals = ();
    
    # Helper to consume doc block arrays
    my $consume_doc = sub {
        my @lines;
        for my $l (@doc_buffer) {
            $l =~ s/^\s*\*\s?//; # Strip leading asterisks
            $l =~ s/\s+$//;      # Strip trailing spaces
            push @lines, $l if $l =~ /\S/ || @lines;
        }
        @doc_buffer = ();
        return ("", "") unless @lines;
        
        my $abstract = shift @lines;
        my $discussion = join(" ", grep { /\S/ } @lines);
        return ($abstract, $discussion);
    };
    
    # Helper to parse and store method signatures
    my $process_method = sub {
        my ($str) = @_;
        $str =~ s/\s+/ /g;     # compact spaces
        $str =~ s/\{.*//;      # strip inline bodies
        $str =~ s/;\s*$//;     # strip terminating semicolon
        $str =~ s/\s+$//;
        
        my $decl = $str;
        return unless $str =~ /^([-+])\s*\(([^)]+)\)\s*(.*)$/;
        
        my $scope = $1 eq '+' ? 'class' : 'instance';
        my $ret   = $2;
        my $sig   = $3;
        
        my $name = "";
        my @params = ();
        
        if ($sig !~ /:/) {
            $name = $sig;
        } else {
            # Parse parameters: NameSegment:(Type)paramName
            while ($sig =~ /([A-Za-z0-9_]+):\s*\(([^)]+)\)\s*([A-Za-z0-9_]+)/g) {
                $name .= "$1:";
                push @params, { type => $2, name => $3 };
            }
        }
        
        return if $name =~ /^_/; # Skip internal / private methods
        
        my ($abstract, $discussion) = $consume_doc->();
        my $sym = {
            kind        => 'method',
            scope       => $scope,
            name        => $name,
            declaration => $decl,
            returnType  => $ret
        };
        $sym->{parameters} = \@params if @params;
        $sym->{abstract}   = $abstract if $abstract;
        $sym->{discussion} = $discussion if $discussion;
        
        push @{$current_topic->{symbols}}, $sym;
    };

    while (my $line = <$fh>) {
        chomp $line;
        
        # --- Multi-line Doc State ---
        if ($state eq 'doc') {
            if ($line =~ m{(.*?)\*/}) {
                push @doc_buffer, $1;
                $state = 'search';
            } else {
                push @doc_buffer, $line;
            }
            next;
        }
        
        # --- Multi-line Typedef State ---
        if ($state eq 'typedef') {
            # Stop if we hit a blank line, an Obj-J tag, or preprocessor tag
            if ($line =~ /^\s*$/ || $line =~ /^\s*\@/ || $line =~ /^\s*\#/) {
                my ($abstract, $discussion) = $consume_doc->();
                my $sym = {
                    kind        => 'typedef',
                    name        => $typedef_name,
                    declaration => $typedef_decl
                };
                $sym->{values}   = [@typedef_vals] if @typedef_vals;
                $sym->{abstract} = $abstract if $abstract;
                push @{$current_topic->{symbols}}, $sym;
                
                $state = 'search';
                # Intentionally fallthrough to re-evaluate this line in 'search' mode
            } else {
                $typedef_decl .= "\n$line";
                if ($line =~ /([A-Za-z0-9_]+)\s*=\s*(.*?);/) {
                    push @typedef_vals, { name => $1, value => $2 };
                }
                next;
            }
        }
        
        # --- Multi-line Method State ---
        if ($state eq 'method') {
            $method_str .= " " . $line;
            # End of signature is either start of body `{` or protocol declaration `;`
            if ($method_str =~ /\{/ || $method_str =~ /;\s*$/) {
                $process_method->($method_str);
                $method_str = "";
                $state = 'search';
            }
            next;
        }

        # --- Base Search State ---
        
        # 1. Detect DocBlock Starts
        if ($line =~ m{/\*\!(.*)}) {
            my $rest = $1;
            if ($rest =~ m{(.*?)\*/}) {
                push @doc_buffer, $1;
            } else {
                push @doc_buffer, $rest;
                $state = 'doc';
            }
            next;
        }
        
        # 2. Pragma Marks
        if ($line =~ /^\s*\#pragma\s+mark\s+-(?:\s*$)/) {
            next; # Ignore blank separators
        }
        if ($line =~ /^\s*\#pragma\s+mark\s+(.+)$/) {
            my $title = $1;
            $title =~ s/^-?\s*//; # Clean leading hyphen if written like `#pragma mark - Title`
            $title =~ s/\s+$//;
            
            if (@{$current_topic->{symbols}}) {
                push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
            }
            $current_topic = { title => $title, symbols => [] };
            next;
        }
        
        # 3. Class Implementation
        if ($line =~ /^\s*\@(implementation|interface)\s+([A-Za-z0-9_]+)(?:\s*:\s*([A-Za-z0-9_]+))?/) {
            $class_decl = $line;
            $class_name = $2;
            $superclass = $3 || "";
            
            my ($abstract, $discussion) = $consume_doc->();
            $class_abstract = $abstract;
            $class_discussion = $discussion;
            next;
        }
        
        # 4. Typedefs
        if ($line =~ /^\s*\@typedef\s+([A-Za-z0-9_]+)/) {
            $typedef_name = $1;
            $typedef_decl = $line;
            $state = 'typedef';
            @typedef_vals = ();
            next;
        }
        
        # 5. Global Variables
        if ($line =~ /^\s*var\s+([A-Za-z0-9_]+)\s*=\s*(.*?);/) {
            my $name = $1;
            my $val = $2;
            my ($abstract, $discussion) = $consume_doc->();
            my $sym = {
                kind        => 'global_variable',
                name        => $name,
                declaration => "var $name = $val",
                type        => 'float' # Extrapolated for simplicity
            };
            $sym->{abstract} = $abstract if $abstract;
            push @{$current_topic->{symbols}}, $sym;
            next;
        }
        
        # 6. Method Starts (+ or -)
        if ($line =~ /^([-+])\s*\(/) {
            $method_str = $line;
            if ($method_str =~ /\{/ || $method_str =~ /;\s*$/) {
                $process_method->($method_str);
            } else {
                $state = 'method';
            }
            next;
        }
    }
    
    close $fh;
    
    # Flush remaining topic
    if (@{$current_topic->{symbols}}) {
        push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
    }
    
    # Only return if we found a valid Objective-J class implementation
    if ($class_name) {
        my $module = ($filepath =~ m{/Foundation/}) ? "Foundation" : "AppKit";
        return {
            metadata => {
                module         => $module,
                framework      => "Cappuccino",
                role           => "class",
                title          => $class_name,
                superclass     => $superclass,
                navigatorTitle => $class_name
            },
            primaryContent => {
                declaration => $class_decl,
                abstract    => $class_abstract,
                discussion  => $class_discussion
            },
            topics => \@topics
        };
    }
    
    return undef; # If no class was found in the file
}