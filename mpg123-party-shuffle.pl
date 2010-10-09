#!/usr/bin/perl

# using open2 and a fifo to control mpg123.  this is mostly a demonstration
# about how to combining open2 and IO::Select

use warnings;
use strict;

use IO::Select;
use Fcntl;
use IPC::Open2;
use List::Util qw(shuffle);

my $dirs = [grep {-d $_} @ARGV];
print <<__USAGE__ and exit unless @$dirs;
useage: mpg123-party-shuffle.pl <directory directory ...>
__USAGE__

my $pid = open2(my $mpg123_out, my $mpg123_in, "mpg321", "-R", "-");
# my $pid = open2(my $mpg123_out, my $mpg123_in, "mpg123", "--remote");

my $select = IO::Select->new();
$select->add(\*STDIN);
$select->add($mpg123_out);

# add fifo interface if it exists.
if (-p "fifo") {
    sysopen FIFO, "fifo", O_RDONLY | O_NONBLOCK;
    $select->add(\*FIFO);
}

my @queue = ();
_fill_queue(\@queue, $dirs, 5);


while (1) {
    foreach my $fh ($select->can_read(0.25)) {
        my $ret = sysread $fh, my $in, 1024;

        if ($fh == $mpg123_out) {
            if ($in =~ m/^\@P 0$/m or $in =~ m/^\@R MPG123/m) {
                # we've just finished a track or we've just started up

                my $track = shift(@queue);
                print "playing $track\n";
                print $mpg123_in "l $track\n";
            }
            elsif ($in =~ m/^\@P 1$/) { print "paused\n"; }
            elsif ($in =~ m/^\@P 2$/) { print "resumed\n"; }
        }
        elsif ($fh == \*FIFO or $fh == \*STDIN) {
            chomp($in);

            my ($cmd, @args) = split(" ", $in);
            next unless $cmd;

            if    ($cmd eq 'help') { _print_help(); }
            elsif ($cmd eq 'next') { print $mpg123_in "stop\n"; }
            elsif ($cmd eq 'stop' or $cmd eq 'start') {
                print $mpg123_in "pause\n";
            }
            elsif ($cmd eq 'quit') {
                $select->remove($mpg123_out);
                print $mpg123_in "quit\n";
                goto EXIT;
            }
            elsif ($cmd eq 'list' or $cmd eq 'queue') {
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'remove') {
                _remove_from_queue(\@queue, \@args);
                _fill_queue(\@queue, $dirs, 5);
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'clear') {
                print "clearing queue!\n";
                @queue = ();
                _fill_queue(\@queue, $dirs, 5);
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'add') {
                _add_to_queue(\@queue, \@args);
                _print_queue(\@queue);
            }
            else { print $mpg123_in "$in\n"; }
        }

    }

    _fill_queue(\@queue, $dirs, 5) if @queue < 5;
}

EXIT:
waitpid($pid, 0);


# this starts with a list (a reference to a list) of directories and
# descends them randomly until it gets an mp3.  note this is means songs
# will not have the same chance of being picked -- files further down the
# tree are less likely to be chosen.  this is by design.  it is so i don't
# have to load up and maintain a database of songs.  there's probably a
# better way to do this than goto/RESET, but whatevers.
sub _get_random_mp3 {
    my ($dirs) = @_;

    RESET:
    my $inode = (shuffle(@$dirs))[0];
    $inode =~ s/\/$//g;


    # descend down directories until we hit a file
    while (not -f $inode) {
        opendir my $dh, $inode or warn "Can't opendir $inode ($!)"
                                    and goto RESET;
        my @inodes = grep { not m/^\./ } readdir $dh;
        closedir $dh;

        $inode = "$inode/".(shuffle(@inodes))[0];
    }

    # make sure the file's an mp3
    goto RESET unless $inode =~ m/.mp3$/i;

    return $inode;
}

# fill the $queue from mp3s chosen from $dirs so that $queue has at least
# $num songs on it.  returns the number of tracks added.
sub _fill_queue {
    my ($queue, $dirs, $num) = @_;
    $num ||= 5;

    my $len = @$queue;

    for (my $i=@$queue; $i < $num; $i++) {
        push @$queue, _get_random_mp3($dirs);
    }

    return @$queue - $len;
}

sub _print_queue {
    my ($queue) = @_;

    my $i = 0;
    print map { $i++ . ": $_\n" } @$queue;
}

sub _print_help {
    print <<__HELP__;
next => stops the current track and go to the next one
stop/start => pause/unpause the player in the current track
quit => quit
list, queue => show the current queue
remove [#|head|tail] => remove an item from the queue.  defaults to, oh,
    head.  everything else goes straight to mpg123
add [#|head|tail] <file> => add an item to the queue at the given position.
    defaults to the end (so acts like a push).  er, i guess if you have a
    file with a numeric name (or 'head' or 'tail') then you'll have to
    explicitly state the position.
clear => clear and refill the queue
__HELP__
}

sub _remove_from_queue {
    my ($queue, $args) = @_;

    $args->[0] ||= 0;
    $args->[0] = 0 if lc($args->[0]) eq 'head';
    $args->[0] = -1 if lc($args->[0]) eq 'tail';
    $args->[0] = -1 if $args->[0] > @$queue;

    my $removed = splice @$queue, $args->[0], 1;
    print "removed $removed\n";
}

sub _add_to_queue {
    my ($queue, $args) = @_;

    if (@$args == 0) {
        print "add needs a filename\n";
        return;
    }

    my $pos = -1;
    if ($args->[0] =~ m/^(?:head|tail|\d+)$/i) {
        $pos = shift(@$args);
        $pos = -1 if $pos eq 'tail';
        $pos = 0 if $pos eq 'head';
    }

    my $filename = join(" ", @$args);
    if (not -f $filename) {
        print "$filename is not a file?\n";
        return;
    }

    if ($pos == -1) { push @$queue, $filename; }
    elsif ($pos == 0) { unshift @$queue, $filename; }
    else { splice @$queue, $pos, 0, $filename; }
}

