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

    my @topics;
    my $current_topic = { title => "General", symbols => [] };

    my @doc_buffer;
    my $state = 'search';
    my $method_str = "";

    my $typedef_name = "";
    my $typedef_decl = "";
    my @typedef_vals = ();

    # Helper to consume doc blocks, retaining structure
    my $consume_doc = sub {
        my @lines;
        for my $l (@doc_buffer) {
            $l =~ s/^\s*\*\s?//; # Strip leading asterisks
            $l =~ s/\s+$//;      # Strip trailing spaces
            push @lines, $l;
        }
        @doc_buffer = ();

        # Trim leading and trailing empty lines
        while (@lines && $lines[0] =~ /^\s*$/) { shift @lines; }
        while (@lines && $lines[-1] =~ /^\s*$/) { pop @lines; }

        return ("", "") unless @lines;

        my $abstract = shift @lines;
        my $discussion = join("\n", @lines); # Maintain newlines for @code

        return ($abstract, $discussion);
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
                if ($line =~ /^\s*$/ || $line =~ /^\s*\@/ || $line =~ /^\s*\#/) {
                    my ($abstract, $discussion) = $consume_doc->();
                my $sym = {
                    kind        => 'typedef',
                    name        => $typedef_name,
                    declaration => $typedef_decl
                };
                $sym->{values}     = [@typedef_vals] if @typedef_vals;
                $sym->{abstract}   = $abstract if $abstract;
                $sym->{discussion} = $discussion if $discussion;
                push @{$current_topic->{symbols}}, $sym;

                $state = 'search';
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
            my $clean_line = $line;
            $clean_line =~ s/^\s+//;
            $method_str .= " " . $clean_line;
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
        $title =~ s/^-?\s*//;
        $title =~ s/\s+$//;

        if (@{$current_topic->{symbols}}) {
            push @topics, { title => $current_topic->{title}, symbols => [@{$current_topic->{symbols}}] };
        }
        $current_topic = { title => $title, symbols => [] };
        next;
    }

    # 3. Class Implementation (Prevent Category from overwriting Main class)
    # Bulletproof Objective-C/J Class Parser:
    # $1 = implementation|interface
    # $2 = ClassName
    # $3 = SuperClass (optional)
    # $4 = CategoryName (optional, can be empty for extensions `()`)
    # $5 = Protocols (optional, e.g., `<CPTheme>`)
    if ($line =~ /^\s*\@(implementation|interface)\s+([A-Za-z0-9_]+)(?:\s*:\s*([A-Za-z0-9_]+))?(?:\s*\(\s*([A-Za-z0-9_]*)\s*\))?(?:\s*<\s*([^>]+)\s*>)?/) {
        my $parsed_cname = $2;
        my $parsed_sclass = $3;
        my $parsed_category = $4;

        # If there are no parenthesis at all, $parsed_category will be mathematically undefined.
        # This separates real primary class declarations from Categories and Extensions.
        if (!defined $parsed_category) {
            # Update if it's the first time we see it, or if it matches the current class (e.g. going from @interface to @implementation)
            if (!$class_name || $class_name eq $parsed_cname) {
                $class_decl = $line;
                $class_decl =~ s/^\s+//;
                $class_name = $parsed_cname;
                $superclass = $parsed_sclass if $parsed_sclass;

                my ($abstract, $discussion) = $consume_doc->();
                $class_abstract = $abstract if $abstract;
                $class_discussion = $discussion if $discussion;
            }
        } else {
            # It is a category like `(CPCoding)` or an extension `()`.
            # We don't overwrite the main class details.
            # However, we must consume the docblock so it doesn't accidentally attach to the next method.
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

    # 5. Global Variables
    if ($line =~ /^\s*var\s+([A-Za-z0-9_]+)\s*=\s*(.*?);/) {
        my $name = $1;
        my $val = $2;
        my ($abstract, $discussion) = $consume_doc->();
        my $sym = {
            kind        => 'global_variable',
            name        => $name,
            declaration => "var $name = $val",
            type        => 'float'
        };
        $sym->{abstract} = $abstract if $abstract;
        $sym->{discussion} = $discussion if $discussion;
        push @{$current_topic->{symbols}}, $sym;
        next;
    }

    # 6. Method Starts (+ or -) tolerating leading spaces
    if ($line =~ /^\s*([-+])\s*\(/) {
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
