#!/usr/bin/env perl

=head1 NAME

detasklister - Remove tasklist blocks from GitHub issues

=head1 SYNOPSIS

detasklister [options] [<issue number or url> ...]

  Options:
    -R, --repo [HOST/]/OWNER/REPO           Selects a GitHub repo to change
    -i, --interactive                       Interactive mode, prompt for each change
    -A, --all-issues                        Modify all issues in a repo 
    -s, --issue-state {open|closed|all}     Filter by issue state when using --all-issues (default: open)
    -n, --dry-run                           Show changes without performing them
    -v, --verbose                           Verbose output
        --debug                             Debugging output
        --help                              Show help message 
=cut

use strict;
use v5.20;

use Getopt::Long qw(:config gnu_getopt auto_abbrev auto_help);
use JSON::PP;
use File::Temp qw(tempfile);
use File::Spec;
use Pod::Usage;

my $tmpdir = File::Spec->tmpdir() or '/tmp'; # Fixes MacOS weirdness with TMPDIR
my $use_color = not $ENV{NO_COLOR};          # https://no-color.org/

### Variables for storing command-line options
my $host;
my $owner;
my $repo;
my $interactive;
my $all_issues;
my $issue_state;
my $dry_run;
## As of writing, GitHub CLI does not support editing comments
## See https://github.com/cli/cli/issues/8409
#my $comments;
my $verbose;
my $debug;

### Utility functions
sub run_cmd {
    my ( $cmd, %args ) = @_;
    say ">>> $cmd" if $verbose or $debug;
    my $output = `$cmd`;
    $output =~ s/\n?$/\n/
      if $output ne '';    # ensure trailing newline in command output
    print $output if $debug or $args{print} or $?;
    exit $?       if $?;
    return $output;
}

sub shell_escape {
    foreach (@_) {
        s/'/'"'"'/g;
        s/^|$/'/g;
    }
    return @_;
}

sub show_diff {
    my ( $old, $new ) = @_;
    my ( $old_file, $old_name ) =
      tempfile( "detasklister.old.XXXXXXXXXX", DIR => $tmpdir );
    my ( $new_file, $new_name ) =
      tempfile( "detasklister.new.XXXXXXXXXX", DIR => $tmpdir );
    print $old_file $old;
    print $new_file $new;
    my $color_opt = $use_color ? '--color=always' : '--color=never';
    run_cmd( "diff -u $color_opt $old_name $new_name || :", print => 1 );
}

unless ( @ARGV ) {
    pod2usage(1);
}

GetOptions(
    "repo|R=s" => sub {

        ## Validate and parses repo string format
        my ( $opt_name, $opt_value ) = @_;
        $opt_value =~ m'^
            (?:(?<host>[^/]+)/)?
            (?<owner>[^/]+)/
            (?<repo>[^/]+)
        $'x
          or die "Expected the '[HOST]/OWNER/REPO' format, got '$opt_value'\n";
        ( $host, $owner, $repo ) = @+{ 'host', 'owner', 'repo' };
    },
    "interactive|i"   => \$interactive,
    "all-issues|A"    => \$all_issues,
    "issue-state|s=s" => \$issue_state,
    "verbose|v"       => \$verbose,
    "debug"           => \$debug,
    "dry-run|n"       => \$dry_run,
) or exit 1;

## Validate argument combinations
if ($all_issues) {
    if (@ARGV) {
        die "Cannot combine positional arguments with --all-issues (-A)\n";
    }
    if ( not $repo ) {
        die "--repo (-R) is required when using --all-issues (-A)\n";
    }
    if(not defined $issue_state) {
        $issue_state = 'open';
    }
    if ( not grep /^\Q$issue_state\E$/, 'all', 'open', 'closed' ) {
        die "--issue-state (-s) must be one of 'all', 'open', or 'closed'\n";
    }
}
else {
    if ($issue_state) {
        die "--issue-state (-s) requires --all-issues (-A)\n";
    }
}

## construct --json flag for `gh issue view` command
my @json_fields = ( 'url', 'body' );
my $json_opt    = "--json '@{[join(',', @json_fields )]}'";

## construct --repo flag for `gh issue view` and `gh issue list` commands
my $repo_str = join( '/', grep( !/^$/, $host, $owner, $repo ) );
my $repo_opt = $repo_str ? "--repo @{[ shell_escape $repo_str ]}" : '';

foreach (@ARGV) {
    ## Validate issue format. Should be either issue number or an issue URL.
    m'^(#?\d+|https?://.+?/.+?/.+?/issues/\d+)$'
      or die "Invalid issue format '$_'\n";
}

my @issue_names;
if ( not $all_issues ) {
    @issue_names = @ARGV;
}
else {
    my $cmd =
"gh issue list $repo_opt --json url --state $issue_state --limit 2147483647";
    my $json = decode_json( run_cmd($cmd) );
    @issue_names = map { $_->{url} } @$json;
}

foreach my $issue_name (@issue_names) {
    ## Fetch the issues with GH CLI
    my $issue = decode_json(
        run_cmd("gh issue view --json 'url,body' $repo_opt '$issue_name'") );

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
        my ($context) = $body =~ /(
            (?:.*?\n){0,5}
            \Q$outer\E
            (?:.*?\n){0,5}
        )/xs;
        my $choice;
        if ( $interactive and not $yes_to_all ) {
            my $context_changes = ( $context =~ s/\Q$outer\E/$inner/r );
            show_diff( $context, $context_changes );
            my $input;
            do {
                print "\nRemove this tasklist block [y/n/a/d/q]? ";
                $input = <STDIN>;
            } until ($choice) = ( $input =~ /^ *([ynadq]) *$/i );

            $choice = lc($choice);
            if    ( $choice eq 'a' ) { $yes_to_all = 1; }
            elsif ( $choice eq 'd' ) { last TASKLIST_IN_ISSUE; }
            elsif ( $choice eq 'q' ) { die "Quit\n"; }
        }
        if ( not $interactive or $yes_to_all or $choice eq 'y' ) {
            $changes =~ s/\Q$outer\E/$inner/;
        }
    }
    if ( $body eq $changes ) {
        say "No changes to make for $issue_name";
        next;
    }
    my ( $changes_file, $changes_name ) =
      tempfile( "detasklister.changes.XXXXXXXXXX", DIR => $tmpdir );
    print $changes_file $changes;
    my $cmd = "gh issue edit '$issue_name' --body-file '$changes_name'";
    if ($dry_run) {
        say ">>> $cmd";
        show_diff( $body, $changes );
        next;
    }
    say "Updating $issue_name...";
    run_cmd $cmd;
    say "Updated $issue_name\n";
}

