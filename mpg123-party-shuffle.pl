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
    # sysopen FIFO, "fifo", O_RDONLY | O_NONBLOCK;
    sysopen FIFO, "fifo", O_RDWR;
    $select->add(\*FIFO);
}

my @queue = ();
_fill_queue(\@queue, $dirs, 5);


while (1) {
    foreach my $fh ($select->can_read(0.25)) {
        my $ret = sysread $fh, my $in, 1024;

        if ($fh == $mpg123_out) {
            # print "From mpg123:\n$in\n" unless $in =~ m/^\@F/;
            if ($in =~ m/^\@P 0$/m or $in =~ m/^\@R MPG123$/m) {
                my $track = shift(@queue);
                print "playing $track\n";
                print $mpg123_in "l $track\n";
            }
        }
        elsif ($fh == \*FIFO or $fh == \*STDIN) {
            # print "From FIFO or STDIN (sending to mpg123):\n$in\n";
            print $mpg123_in $in;
        }

    }

    _fill_queue(\@queue, $dirs, 5) if @queue < 5;
}


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

