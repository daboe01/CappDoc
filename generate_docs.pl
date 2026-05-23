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
find({
    wanted => sub {
        # Skip testsuite directories entirely
        if (-d $_ && $_ =~ /testsuite/i) {
            $File::Find::prune = 1;
            return;
        }
        # Keep only .j files
        if (-f $_ && /\.j$/) {
            push @files, $File::Find::name;
        }
    },
    no_chdir => 1,
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

    # Safely categorize the module based on the path
    my $module = "Unknown";
    if ($filepath =~ m{/Foundation/}i) {
        $module = "Foundation";
    } elsif ($filepath =~ m{/AppKit/}i) {
        $module = "AppKit";
    }

    my $class_name = "";
    my $superclass = "";
    my $class_decl = "";
    my $class_abstract = "";
    my $class_discussion = "";
    my $class_deprecated = "";
    
    my @topics;
    my $current_topic = { title => "General", symbols => [] };
    
    my @doc_buffer;
    my $state = 'search';
    my $method_str = "";
    my $brace_depth = 0;
    
    my $typedef_name = "";
    my $typedef_decl = "";
    my @typedef_vals = ();
    
    # Helper to consume doc blocks, retaining structure
    my $consume_doc = sub {
        my @lines;
        my $deprecated = "";
        for my $l (@doc_buffer) {
            $l =~ s/^\s*\*\s?//; # Strip leading asterisks
            $l =~ s/\s+$//;      # Strip trailing spaces
            
            # Extract @deprecated directives and their descriptive text
            if ($l =~ /^\@deprecated\s+(.*)/i) {
                $deprecated = $1;
            } else {
                push @lines, $l;
            }
        }
        @doc_buffer = ();
        
        # Trim leading and trailing empty lines
        while (@lines && $lines[0] =~ /^\s*$/) { shift @lines; }
        while (@lines && $lines[-1] =~ /^\s*$/) { pop @lines; }
        
        return ("", "", "") unless @lines || $deprecated;
        
        my $abstract = shift @lines || "";
        my $discussion = join("\n", @lines); # Maintain newlines for @code
        
        return ($abstract, $discussion, $deprecated);
    };
    
    # Helper to accurately count braces ignoring comments and strings
    my $count_braces = sub {
        my ($str) = @_;
        $str =~ s/\/\/.*//;       # Remove line comments
        $str =~ s/"[^"]*"//g;     # Remove double quoted strings
        $str =~ s/'[^']*'//g;     # Remove single quoted strings
        my $open  = () = $str =~ /\{/g;
        my $close = () = $str =~ /\}/g;
        return $open - $close;
    };
    
    # Helper to parse and store method signatures
    my $process_method = sub {
        my ($str) = @_;
        
        # Strip inline bodies, trailing semicolons
        $str =~ s/\{.*//;
        $str =~ s/;\s*$//;
        $str =~ s/\s+$//;
        
        # Save a cleaner declaration string
        my $decl = $str;
        $decl =~ s/^\s+//;
        $decl =~ s/\s+/ /g; # compact multiple spaces purely for display
        
        return unless $str =~ /^\s*([-+])\s*\(([^)]+)\)\s*(.*)$/;
        
        my $scope = $1 eq '+' ? 'class' : 'instance';
        my $ret   = $2;
        my $sig   = $3;
        
        my $name = "";
        my @params = ();
        
        if ($sig !~ /:/) {
            $name = $sig;
            $name =~ s/\s+//g;
        } else {
            # Parse parameters: Segment:(Type)argName
            while ($sig =~ /([A-Za-z0-9_]+):\s*\(([^)]+)\)\s*([A-Za-z0-9_]+)/g) {
                $name .= "$1:";
                push @params, { type => $2, name => $3 };
            }
        }
        
        return if $name =~ /^_/; # Skip internal / private methods
        
        my ($abstract, $discussion, $deprecated) = $consume_doc->();
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
        $sym->{deprecated} = $deprecated if $deprecated;
        
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
            if ($line =~ /^\s*$/ || $line =~ /^\s*\@/ || $line =~ /^\s*\#/) {
                my ($abstract, $discussion, $deprecated) = $consume_doc->();
                my $sym = {
                    kind        => 'typedef',
                    name        => $typedef_name,
                    declaration => $typedef_decl
                };
                $sym->{values}     = [@typedef_vals] if @typedef_vals;
                $sym->{abstract}   = $abstract if $abstract;
                $sym->{discussion} = $discussion if $discussion;
                $sym->{deprecated} = $deprecated if $deprecated;
                push @{$current_topic->{symbols}}, $sym;
                
                $state = 'search';
            } else {
                $typedef_decl .= "\n$line";
                # Extract constants with option for deprecated inline comments
                # Match: CPSwitchButton = 3; // Deprecated, use CPCheckBox instead.
                if ($line =~ /([A-Za-z0-9_]+)\s*=\s*([^;\/]+)\s*;\s*(?:\/\/\s*(.*))?/) {
                    my $val_name = $1;
                    my $val_value = $2;
                    my $val_comment = $3 || "";
                    
                    $val_value =~ s/\s+$//;
                    $val_comment =~ s/\s+$//;
                    
                    my $val_dep = "";
                    if ($val_comment =~ /deprecated/i) {
                        $val_dep = $val_comment;
                    }
                    
                    push @typedef_vals, { 
                        name => $val_name, 
                        value => $val_value, 
                        comment => $val_comment,
                        deprecated => $val_dep || undef
                    };
                }
                next;
            }
        }
        
        # --- Multi-line Method Signature State ---
        if ($state eq 'method_sig') {
            my $clean_line = $line;
            $clean_line =~ s/^\s+//;
            $method_str .= " " . $clean_line;
            
            if ($method_str =~ /\{/ || $method_str =~ /;\s*$/) {
                $process_method->($method_str);
                
                # Check if we should transition to skipping the body block
                if ($method_str =~ /\{/) {
                    $state = 'in_body';
                    $brace_depth = $count_braces->($method_str);
                    $state = 'search' if $brace_depth <= 0;
                } else {
                    $state = 'search';
                }
                $method_str = "";
            }
            next;
        }
        
        # --- Inside Method Body State ---
        if ($state eq 'in_body') {
            $brace_depth += $count_braces->($line);
            
            if ($brace_depth <= 0) {
                $state = 'search';
                $brace_depth = 0;
            }
            next; # Skip all lines while inside a method body!
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
            $title =~ s/^-?\s*//; 
            $title =~ s/\s+$//;
            
            if (@{$current_topic->{symbols}}) {
                push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
            }
            $current_topic = { title => $title, symbols => [] };
            next;
        }
        
        # 3. Class Implementation (Prevent Category from overwriting Main class)
        if ($line =~ /^\s*\@(implementation|interface)\s+([A-Za-z0-9_]+)(?:\s*:\s*([A-Za-z0-9_]+))?(?:\s*\(\s*([A-Za-z0-9_]*)\s*\))?(?:\s*<\s*([^>]+)\s*>)?/) {
            my $parsed_cname = $2;
            my $parsed_sclass = $3;
            my $parsed_category = $4;
            
            if (!defined $parsed_category) {
                # Primary class definition
                if (!$class_name || $class_name eq $parsed_cname) {
                    $class_decl = $line;
                    $class_decl =~ s/^\s+//;
                    $class_name = $parsed_cname;
                    $superclass = $parsed_sclass if $parsed_sclass;
                    
                    my ($abstract, $discussion, $deprecated) = $consume_doc->();
                    $class_abstract = $abstract if $abstract;
                    $class_discussion = $discussion if $discussion;
                    $class_deprecated = $deprecated if $deprecated;
                }
            } else {
                # It is a category like `(CPCoding)` or an extension `()`.
                # Start a new topic grouping for it so methods don't bleed into previous pragmas.
                if (@{$current_topic->{symbols}}) {
                    push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
                }
                
                my $topic_title = $parsed_category ? "$parsed_category" : "Extension";
                $current_topic = { title => $topic_title, symbols => [] };
                
                $consume_doc->();
            }
            next;
        }
        
        # 4. Typedefs
        if ($line =~ /^\s*\@typedef\s+([A-Za-z0-9_]+)/) {
            $typedef_name = $1;
            $typedef_decl = $line;
            $typedef_decl =~ s/^\s+//;
            $state = 'typedef';
            @typedef_vals = ();
            next;
        }
        
        # 5. Global Variables (Only triggers because we are securely in `search` state outside of method bodies)
        if ($line =~ /^\s*var\s+([A-Za-z0-9_]+)\s*=\s*(.*?);/) {
            my $name = $1;
            my $val = $2;
            my ($abstract, $discussion, $deprecated) = $consume_doc->();
            my $sym = {
                kind        => 'global_variable',
                name        => $name,
                declaration => "var $name = $val",
                type        => 'id'
            };
            $sym->{abstract} = $abstract if $abstract;
            $sym->{discussion} = $discussion if $discussion;
            $sym->{deprecated} = $deprecated if $deprecated;
            push @{$current_topic->{symbols}}, $sym;
            next;
        }
        
        # 6. Method Starts (+ or -) tolerating leading spaces
        if ($line =~ /^\s*([-+])\s*\(/) {
            $method_str = $line;
            if ($method_str =~ /\{/ || $method_str =~ /;\s*$/) {
                $process_method->($method_str);
                
                if ($method_str =~ /\{/) {
                    $state = 'in_body';
                    $brace_depth = $count_braces->($method_str);
                    $state = 'search' if $brace_depth <= 0;
                } else {
                    $state = 'search';
                }
                $method_str = "";
            } else {
                $state = 'method_sig';
            }
            next;
        }
    }
    
    close $fh;
    
    # Check 1: Skip if no class found
    return undef unless $class_name;
    
    # Check 2: Skip any NS* classes
    return undef if $class_name =~ /^NS/;
    
    # Flush remaining topic
    if (@{$current_topic->{symbols}}) {
        push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
    }
    
    return {
        metadata => {
            module         => $module,
            framework      => $module, # Changed from "Cappuccino" to AppKit/Foundation dynamically
            role           => "class",
            title          => $class_name,
            superclass     => $superclass,
            navigatorTitle => $class_name,
            deprecated     => $class_deprecated || undef
        },
        primaryContent => {
            declaration => $class_decl,
            abstract    => $class_abstract,
            discussion  => $class_discussion
        },
        topics => \@topics
    };
}
