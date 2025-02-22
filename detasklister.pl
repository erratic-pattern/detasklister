#!/usr/bin/env perl

=head1 NAME

detasklister - Remove tasklist blocks from GitHub issues

=head1 SYNOPSIS

detasklister [options] [<issue number or url> ...]

  Options:
    -R, --repo [HOST/]/OWNER/REPO           Selects a GitHub repo to change
    -i, --interactive                       Interactive mode, prompt for each change
    -A, --all-issues                        Modify all issues in a repo 
    -s, --issue-state {open|closed|all}     Filter by issue state when using --all-issues (default: all)
    -n, --dry-run                           Show changes without performing them
    -v, --verbose                           Verbose output
        --debug                             Debugging output
        --suppress-unchanged                Do not show any output from unchanged issues
    -C  --context int                       Display N lines of context in interactive diffs (default: 5)
    -h, --help                              Show help message 
=cut

use strict;
use warnings;
use v5.20;
use utf8;

use Getopt::Long qw(:config gnu_getopt auto_abbrev);
use JSON::PP;
use File::Temp qw(tempfile);
use File::Spec;
use Pod::Usage;

### Constants

my $use_color =
  !( defined $ENV{NO_COLOR} && $ENV{NO_COLOR} ne '' ) && -t select;
my @issue_state_options = qw(open closed all);

### Variables for storing command-line options

my $repo;
my %repo_parts;    # Hash of host,owner,repo parts
my $interactive;
my $all_issues;
my $issue_state;
my $dry_run;
## As of writing, GitHub CLI does not support editing comments
## See https://github.com/cli/cli/issues/8409
#my $comments;
my $verbose;
my $debug;
my $suppress_unchanged;
my $num_context;

### Utility functions

# Run a shell command and return the output. Respects command-line logging options.
#
# Keyword arguments:
#   print_output    if true, always print output. if false, never print output.
#                   By default, print on error or when --debug flag is used.
#
#   ignore_error    by default, an error code will exit the program.
#                   Set this flag to ignore the exit code.
sub run_cmd {
    my ( $cmd, %args ) = @_;
    say ">>> $cmd" if $verbose || $debug;
    my $output = `$cmd`;
    $output =~ s/\n?$/\n/
      if $output ne '';    # ensure trailing newline in command output
    print $output if $debug || $args{print_output} || $?;
    exit $?       if $? && !$args{ignore_error};
    return $output;
}

# Escape shell argument with single quotes.
#
# Example argument:
#   don't worry be happy
# Returns:
#   'don'"'"'t worry be happy'
sub shell_escape {
    foreach (@_) {
        s/'/'"'"'/g;
        s/^|$/'/g;
    }
    return @_;
}

# Create and write to a temp file
sub write_temp {
    my ( $name, $contents, %args ) = @_;
    state $tmpdir = File::Spec->tmpdir();
    $args{DIR} = $tmpdir unless $args{DIR};
    my ( $fh, $fname ) = tempfile( "detasklister.$name.XXXXXXXXXX", %args );
    binmode( $fh, ":utf8" );
    print $fh $contents;
    return ( $fname, $fh );
}

# Display a diff to the user with the system `diff` command.
sub show_diff {
    my ( $old, $new, %args ) = @_;
    $args{name} = "diff" unless defined $args{name};
    my ($old_name) = write_temp( "$args{name}.old", $old );
    my ($new_name) = write_temp( "$args{name}.new", $new );
    my $color_opt  = $use_color ? '--color=always' : '--color=never';
    run_cmd(
        "diff -u $color_opt $old_name $new_name",
        print_output => 1,
        ignore_error => 1
    );
}

# Parses the [HOST/]OWNER/REPO format
sub parse_repo_opt {
    my ( $opt_name, $opt_value ) = @_;
    $opt_value =~ m'^
            (?:(?<host>[^/]+)/)?
            (?<owner>[^/]+)/
            (?<repo>[^/]+)
        $'x
      or die "Expected the '[HOST]/OWNER/REPO' format, got '$opt_value'\n";
    %repo_parts = %+;
    $repo       = $opt_value;
}

# Parse an issue argument string and returns the number as a string
sub parse_issue {
    ($_) = @_ if @_;
    return $1 if m'^(?|#?(\d+)|https?://.+?/.+?/.+?/issues/(\d+)/?)$';
}

### Show help when there are no arguments

pod2usage(1) unless @ARGV;

### Parse command-line options

GetOptions(
    "repo|R=s"           => \&parse_repo_opt,
    "interactive|i"      => \$interactive,
    "all-issues|A"       => \$all_issues,
    "issue-state|s=s"    => \$issue_state,
    "dry-run|n"          => \$dry_run,
    "verbose|v"          => \$verbose,
    "debug"              => \$debug,
    "suppress-unchanged" => \$suppress_unchanged,
    "context|C=i"        => \$num_context,
    "help|h"             => sub { podusage(1); },
) or exit 1;

### Validate command-line arguments

if ( defined $all_issues ) {
    if (@ARGV) {
        die "Cannot combine positional arguments with --all-issues (-A)\n";
    }
    if ( !defined $repo ) {
        die "--repo (-R) is required when using --all-issues (-A)\n";
    }
    if ( defined $issue_state
        && !grep( /^\Q$issue_state\E$/, @issue_state_options ) )
    {
        die '--issue-state (-s) must be one of '
          . join( ', ', @issue_state_options ) . "\n";
    }
}
elsif ( defined $issue_state ) {
    die "--issue-state (-s) requires --all-issues (-A)\n";
}

if ( !defined $interactive && defined $num_context ) {
    die "--context (-C) can only used with --interactive (-i)\n";
}
if ( defined $num_context && $num_context < 0 ) {
    die "--context (-C) must be a non-negative number\n";
}

# Validate issue format. Should be either issue number or an issue URL.
foreach (@ARGV) {
    parse_issue or die "Invalid issue format '$_'\n";
}

### Default option values

$issue_state = 'all' if !defined $issue_state;
$num_context = 5     if !defined $num_context;

### Autoflush STDOUT in interactive mode

# Prevents commands like `tee` from interfering with flush behavior
STDOUT->autoflush(1) if $interactive;

### Prepare common GH CLI options

# construct --repo flag for `gh issue view` and `gh issue list` commands
my $repo_opt = $repo ? "--repo @{[ shell_escape $repo ]}" : '';

### Prepare the list of issues to read/edit

my @issue_names;
if ( !$all_issues ) {
    @issue_names = @ARGV;
}
else {
    # options for `gh issue list`
    my $list_opts =
      "$repo_opt --json url --state $issue_state --limit 2147483647";
    my $cmd  = "gh issue list $list_opts";
    my $json = decode_json( run_cmd($cmd) );
    @issue_names = map { $_->{url} } @$json;
}

### Main view/edit loop

foreach my $issue_name (@issue_names) {
    ## Fetch the issues with GH CLI
    my $issue_number = parse_issue $issue_name;
    my $view_opts    = "--json 'url,body'";
    if ($repo_opt) {
        $view_opts .= " $repo_opt '$issue_number'";
    }
    else {
        $view_opts .= " '$issue_name'";
    }
    my $issue = decode_json( run_cmd("gh issue view $view_opts") );
    ## Search/Replace tasklist blocks
    my $body    = $issue->{body};
    my $changes = $body;
    my $yes_to_all;
  TASKLIST_IN_ISSUE:
    while (
        $body =~ m' 
            (?<outer>
                ^\h*```\[tasklist\]\h*\r?\n
                    (?<inner>.*?)
                ```\h*\r?$
            )
        'xmsg
      )
    {
        my ( $outer, $inner ) = @+{ 'outer', 'inner' };

        # Grab the context around the tasklist
        # This is done as a separate regex to avoid messing up the looping
        # behavior of the /g modifier when tasklists appear in the sliding
        # context window
        my ($context) = $body =~ /(
            (?:\N*\n){0,$num_context}
            \Q$outer\E
            (?:\N*\n){0,$num_context}
        )/xms;

        # non-interactive mode
        if ( !$interactive || $yes_to_all ) {
            $changes =~ s/\Q$outer\E/$inner/;
        }

        # interactive mode
        else {
            my $choice;

            # apply the change to the context area and display as a diff to the
            # user
            my $context_changes = ( $context =~ s/\Q$outer\E/$inner/r );
            show_diff( $context, $context_changes,
                name => "issue.$issue_number.tasklist" );

            # prompt for input
            my $input;
          PROMPT:
            do {
                print "\nRemove this tasklist block [y/n/a/d/q/?]? ";
                $input = <STDIN>;
            } until ($choice) = ( $input =~ /^ *([ynadq?]) *$/i );

            # process the user's input
            $choice = lc($choice);
            if    ( $choice eq 'y' ) { $changes =~ s/\Q$outer\E/$inner/ }
            elsif ( $choice eq 'n' ) { next TASKLIST_IN_ISSUE; }
            elsif ( $choice eq 'a' ) { $yes_to_all = 1; }
            elsif ( $choice eq 'd' ) { last TASKLIST_IN_ISSUE; }
            elsif ( $choice eq 'q' ) { die "Quit\n"; }
            elsif ( $choice eq '?' ) {
                print <<~'END';
                    y - stage this change
                    n - do not stage this change
                    q - quit; do not stage this change or any remaining ones
                    a - stage this change and all later changes in this issue
                    d - do not stage this change or any of the later changes in this issue
                    ? - print help
                END
                goto PROMPT;    # mama mia that's some good spaghetti
            }
            else {
                die <<~END;
                    UNEXPECTED ERROR: received 'impossible' choice '$choice'

                    Please report this as a bug :)
                END
            }
        }
    }
    if ( $body eq $changes ) {
        say "No changes to make for $issue_name" if !$suppress_unchanged;
        next;
    }
    my ($changes_name) = write_temp( "issue.$issue_number.changes", $changes );
    my $edit_opts = "--body-file '$changes_name'";
    if ($repo_opt) {
        $edit_opts .= " $repo_opt '$issue_number'";
    }
    else {
        $edit_opts .= " '$issue_name'";
    }
    my $cmd = "gh issue edit $edit_opts";
    if ($dry_run) {
        say "DRY RUN >>> $cmd";
        show_diff( $body, $changes, name => "issue.$issue_number" );
        next;
    }
    say "Updating $issue_name...";
    run_cmd $cmd;
    say "Updated $issue_name\n";
}

