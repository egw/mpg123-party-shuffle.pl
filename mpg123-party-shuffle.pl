#!/usr/bin/perl

# using open2 and a fifo to control mpg123.  this is mostly a demonstration
# about how to combining open2 and IO::Select

use warnings;
use strict;

use IO::Select;
use Fcntl;
use IPC::Open2;
use List::Util qw(shuffle);

@ARGV = grep {-d $_} @ARGV;
print <<__USAGE__ and exit unless @ARGV;
useage: mpg123-party-shuffle.pl <directories>
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

while (1) {
    foreach my $fh ($select->can_read()) {
        my $ret = sysread $fh, my $in, 1024;

        if ($fh == $mpg123_out) {
            # print "From mpg123:\n$in\n" unless $in =~ m/^\@F/;
            if ($in =~ m/^\@P 0/ or $in =~ m/^\@R MPG123/) {
                my $random_mp3 = _get_random_mp3(\@ARGV);
                print "playing $random_mp3\n";
                print $mpg123_in "l $random_mp3\n";
            }
        }
        elsif ($fh == \*FIFO or $fh == \*STDIN) {
            # print "From FIFO or STDIN (sending to mpg123):\n$in\n";
            print $mpg123_in $in;
        }

    }
}


# this starts with a list (a reference to a list) of directories and
# goes down them randomly until it gets an mp3.  note this is means
# songs will not have the same chance of being picked -- it is related
# to how far down the tree the song is.  this is by design.  it is so
# i don't have to load up and maintain a database of songs.
sub _get_random_mp3 {
    my ($dirs) = @_;

    RESET:
    my $pointer = (shuffle(@$dirs))[0];
    $pointer =~ s/\/$//g;


    # descend down directories until we hit a file
    while (not -f $pointer) {
        opendir my $dh, $pointer or warn "Can't opendir $pointer ($!)"
                                    and goto RESET;
        my @inodes = grep { not m/^\./ } readdir $dh;
        closedir $dh;

        $pointer = "$pointer/".(shuffle(@inodes))[0];
    }

    # make sure the file's an mp3
    goto RESET unless $pointer =~ m/.mp3$/i;

    return $pointer;
}


