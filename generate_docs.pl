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
    open my $fh, '<:encoding(UTF-8)', $filepath or return;

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
        my @raw_lines;
        my $deprecated = "";
        my $brief = "";
        my %param_docs;
        my $return_doc = "";
        my $current_tag = "";
        my $current_param_name = "";

        for my $l (@doc_buffer) {
            $l =~ s/^\s*\*\s?//; # Strip leading asterisks
            $l =~ s/\s+$//;      # Strip trailing spaces

            # 1. Parse HeaderDoc / Doxygen directives
            if ($l =~ /^\s*[@\\]deprecated(?:\s+(.*))?$/i) {
                $current_tag = 'deprecated';
                $deprecated = $1 // "";
                next;
            }
            elsif ($l =~ /^\s*[@\\]brief\s+(.*)$/i) {
                $current_tag = 'brief';
                $brief = $1;
                next;
            }
            elsif ($l =~ /^\s*[@\\]param\s+([A-Za-z0-9_]+)\s*(.*)$/i) {
                $current_tag = 'param';
                $current_param_name = $1;
                $param_docs{$current_param_name} = $2 // "";
                next;
            }
            elsif ($l =~ /^\s*[@\\](?:return|result)\s*(.*)$/i) {
                $current_tag = 'return';
                $return_doc = $1 // "";
                next;
            }
            elsif ($l =~ /^\s*[@\\](ingroup|class|category|file|module|header|framework)\b/i) {
                $current_tag = 'ignore';
                next;
            }
            elsif ($l =~ /^\s*[@\\][a-zA-Z]/) {
                $current_tag = 'ignore';
                next;
            }

            # Blank line resets tag continuation
            if ($l =~ /^\s*$/) {
                $current_tag = "";
                push @raw_lines, "" unless @raw_lines && $raw_lines[-1] eq "";
                next;
            }

            # Multi-line tag continuation
            if ($current_tag eq 'deprecated') {
                $deprecated .= " " . $l;
            }
            elsif ($current_tag eq 'brief') {
                $brief .= " " . $l;
            }
            elsif ($current_tag eq 'param') {
                $param_docs{$current_param_name} .= " " . $l;
            }
            elsif ($current_tag eq 'return') {
                $return_doc .= " " . $l;
            }
            elsif ($current_tag eq 'ignore') {
                next;
            }
            else {
                push @raw_lines, $l;
            }
        }
        @doc_buffer = ();

        # Clean tags and format inline code
        for my $k (keys %param_docs) {
            $param_docs{$k} =~ s/^\s+|\s+$//g;
            $param_docs{$k} =~ s{[@\\]c\s+([A-Za-z0-9_:.()]+)}{<code>$1</code>}g;
            $param_docs{$k} =~ s{\\@}{@}g;
        }
        for my $var (\$return_doc, \$deprecated, \$brief) {
            $$var =~ s/^\s+|\s+$//g;
            $$var =~ s{[@\\]c\s+([A-Za-z0-9_:.()]+)}{<code>$1</code>}g;
            $$var =~ s{\\@}{@}g;
        }

        # Trim leading and trailing empty lines
        while (@raw_lines && $raw_lines[0] =~ /^\s*$/) { shift @raw_lines; }
        while (@raw_lines && $raw_lines[-1] =~ /^\s*$/) { pop @raw_lines; }

        my @processed_lines;
        for my $line (@raw_lines) {
            $line =~ s{[@\\]c\s+([A-Za-z0-9_:.()]+)}{<code>$1</code>}g;
            $line =~ s{\\@}{@}g;
            push @processed_lines, $line;
        }

        my $full_text = join("\n", @processed_lines);
        $full_text =~ s/^\s+|\s+$//g;

        my $abstract = $brief;
        my $discussion = "";

        if ($abstract) {
            $discussion = $full_text;
        } elsif ($full_text) {
            # Split into paragraphs by blank lines
            my @paragraphs = split(/\n\s*\n/, $full_text);
            my $first_p = shift @paragraphs;

            # Flatten newlines within the first paragraph for sentence extraction
            my $p_flattened = $first_p;
            $p_flattened =~ s/\n/ /g;
            $p_flattened =~ s/\s+/ /g;

            # Match first complete sentence ending in a dot
            if ($p_flattened =~ /^(.+?\.)(?:\s+(.*))?$/s) {
                $abstract = $1;
                my $rest_of_p = $2;
                my @disc_parts;
                push @disc_parts, $rest_of_p if defined $rest_of_p && length $rest_of_p;
                push @disc_parts, @paragraphs if @paragraphs;
                $discussion = join("\n\n", @disc_parts);
            } else {
                $abstract = $p_flattened;
                $discussion = join("\n\n", @paragraphs);
            }
        }

        $abstract =~ s/^\s+|\s+$//g if $abstract;
        $discussion =~ s/^\s+|\s+$//g if $discussion;

        return {
            abstract    => $abstract || "",
            discussion  => $discussion || "",
            deprecated  => $deprecated || "",
            param_docs  => \%param_docs,
            return_doc  => $return_doc || ""
        };
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

    # Helper to strip comments and strings temporarily for structural checks
    my $strip_code = sub {
        my ($str) = @_;
        $str =~ s{/\*.*?\*/}{}gs;       # Remove block comments
        $str =~ s{//.*}{}g;              # Remove line comments
        $str =~ s/"(?:[^"\\]|\\.)*"//g;  # Remove double quoted strings
        $str =~ s/'(?:[^'\\]|\\.)*'//g;  # Remove single quoted strings
        return $str;
    };

    # Helper to parse and store method signatures
    my $process_method = sub {
        my ($str) = @_;

        # Strip method body and trailing semicolons safely (ignoring braces inside comments/strings)
        my @masked;
        my $masked_str = $str;
        $masked_str =~ s{(/\*.*?\*/|//.*|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')}{
            push @masked, $1;
            "___TOKEN_" . $#masked . "___";
        }gse;

        $masked_str =~ s/\{.*//s;
            $masked_str =~ s/;\s*$//;
            $masked_str =~ s/\s+$//;

            # Restore original comments/strings for declaration display
            my $decl = $masked_str;
            $decl =~ s{___TOKEN_(\d+)___}{$masked[$1]}ge;
            $decl =~ s/^\s+//;
            $decl =~ s/\s+/ /g;

            # Create a clean version without comments/strings for regex parsing
            my $clean_str = $strip_code->($decl);

            return unless $clean_str =~ /^\s*([-+])\s*(?:\(([^)]+)\))?\s*(.*)$/s;

            my $scope = $1 eq '+' ? 'class' : 'instance';
            my $ret   = $2 // 'id';
            my $sig   = $3;

            $ret =~ s/^\s+|\s+$//g;

            my $name = "";
            my @params = ();

            # Get parsed documentation from docblock
            my $doc_data = $consume_doc->();
            my ($abstract, $discussion, $deprecated, $param_docs, $return_doc) =
            @{$doc_data}{qw(abstract discussion deprecated param_docs return_doc)};

            if ($sig !~ /:/) {
                $name = $sig;
                $name =~ s/\s+//g;
            } else {
                # Parse parameters: Segment:(optional_type)argName or Segment:argName
                while ($sig =~ /([A-Za-z0-9_]+)\s*:\s*(?:\(([^)]+)\))?\s*([A-Za-z0-9_]+)?/g) {
                    my $kw     = $1;
                    my $p_type = $2 // 'id';
                    my $p_name = $3 // '';

                    $name .= "$kw:";
                    $p_type =~ s/^\s+|\s+$//g;
                    $p_name =~ s/^\s+|\s+$//g;

                    my $param = { type => $p_type };
                    $param->{name} = $p_name if length $p_name;

                    # Attach description if documented via @param
                    if ($p_name && exists $param_docs->{$p_name}) {
                        $param->{description} = $param_docs->{$p_name};
                    }

                    push @params, $param;
                }
            }

            return if $name =~ /^_/; # Skip internal / private methods

            my $sym = {
                kind        => 'method',
                scope       => $scope,
                name        => $name,
                declaration => $decl,
                returnType  => $ret
            };
            $sym->{parameters} = \@params if @params;
            $sym->{returns}    = $return_doc if $return_doc;
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
            @doc_buffer = (); # Clear stale, unconsumed docs to prevent them from bleeding into the class block
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
