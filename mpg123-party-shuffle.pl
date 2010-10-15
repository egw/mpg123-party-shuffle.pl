#!/usr/bin/perl

# mpg123 based party shuffler

use warnings;
use strict;

use Encode;
use Fcntl;
use IO::Select;
use IPC::Open2;
use List::Util qw(shuffle);

use LastFM;

my $MIN_QUEUE_SIZE = 5;

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


# sometimes we read faster than mpg123 writes, so we save partial lines
# in a buffer
my ($mpg123_buffer) = ("");
my %mp3_info = ();             # info about the currently playing mp3
my $lastfm_sk = undef;         # last.fm session key for scrobbling
my @queue = ();                # queue of songs
_fill_queue(\@queue, $dirs);

my $lastfm = LWP::UserAgent::LastFM->new();
$lastfm->agent('mpg123-party-shuffler/1.0');
$lastfm->api_key('e356a13fae4326d3489e1380c4605e46');
$lastfm->api_secret('229b9a270843b824e365b2b5ace85f04');

while (1) {

    foreach my $fh ($select->can_read(0.25)) {
        my $ret = sysread $fh, my $in, 1024;

        if ($fh == $mpg123_out) {
            # print "[$in]" unless $in =~ m/^\@F/;

            # the buffer is "full" (i.e. processable) when the
            # last character is a newline.
            $mpg123_buffer .= $in;
            next unless substr($mpg123_buffer, -1) eq "\n";

            # note we do a series of ifs because the buffer could
            # contain more than one line.  TODO: proper split and
            # parse every line.

            if ($mpg123_buffer =~ m/^\@P 0$/m or
                $mpg123_buffer =~ m/^\@R MPG123/m)
            {
                # we've just finished a track or we've just started up
                my $track = shift(@queue);
                %mp3_info = _mpg123_play($track, $mpg123_in, \$lastfm_sk,
                                         \%mp3_info);
            }

            if ($mpg123_buffer =~ m/^\@P 1$/) { print "paused\n"; }

            if ($mpg123_buffer =~ m/^\@P 2$/) { print "resumed\n"; }

            if ($mpg123_buffer =~ m/^\@I ID3:(.*)/) {
                # my version of mpg321 only reads id3v1 tags :( the info
                # is in a fixed-length format, which we parse with unpack.
                # the map removes trailing spaces and encodes to utf8.

                @mp3_info{qw/TITLE ARTIST ALBUM YEAR COMMENT GENRE/} =
                    map {s/\s+$//; encode_utf8($_);}
                    unpack("a30 a30 a30 a4 a30 a30", $1);

                _print_mp3_info(\%mp3_info);

                # scrobble.  perhaps this should be forked or something so
                # the rest of the script isn't blocked.  anyhow turn off
                # scrobbling on error.
                if ($lastfm_sk and $mp3_info{ARTIST} and $mp3_info{TITLE}) {
                    my $ret = $lastfm->call_auth('track.updateNowPlaying',
                        $lastfm_sk,
                        artist => $mp3_info{ARTIST},
                        track  => $mp3_info{TITLE},);

                    print "ERROR w/ track.updateNowPlaying\n".
                        $ret->decoded_content() and $lastfm_sk = undef
                        unless $ret->is_success();
                }
            }

            if ($mpg123_buffer =~ m/^\@F (.*)/m) {
                $mp3_info{MPG123_FRAME_INFO} = [split(' ', $1)];
            }

            # clear the buffer
            $mpg123_buffer = '';
        }
        elsif ($fh == \*FIFO or $fh == \*STDIN) {
            chomp($in);

            my ($cmd, @args) = split(" ", $in);
            next unless $cmd;

            # dispatch.  see _print_help() to read what command is
            # supposed to do what.
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
            elsif ($cmd eq 'list' or $cmd eq 'queue') { _print_queue(\@queue); }
            elsif ($cmd eq 'remove') {
                _remove_from_queue(\@queue, \@args);
                _fill_queue(\@queue, $dirs);
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'play') {
                print "=> 'play' needs a filename\n" and next unless @args;

                %mp3_info = _mpg123_play(join(" ", @args), $mpg123_in,
                                         \$lastfm_sk, \%mp3_info);
            }
            elsif ($cmd eq 'clear') {
                print "clearing queue!\n";
                @queue = ();
                _fill_queue(\@queue, $dirs);
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'add') {
                _add_to_queue(\@queue, \@args);
                _print_queue(\@queue);
            }
            elsif ($cmd eq 'info') {
                _print_mp3_info(\%mp3_info);
            }
            elsif ($cmd eq 'scrobble') {
                if (not @args) {
                    print "scrobble <session key> or ".
                        "scrobble off.  scrobbling is currently ".
                        ($lastfm_sk ? "on" : "off").
                        "\n";
                }
                elsif (lc($args[0]) eq 'off') {
                    print "scrobbling turned off\n";
                    $lastfm_sk = undef;
                }
                else {
                    print "scrobbling turned on\n";
                    $lastfm_sk = $args[0];
                }
            }
            else { print $mpg123_in "$in\n"; }
        }

    }

    _fill_queue(\@queue, $dirs) if @queue < $MIN_QUEUE_SIZE;
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
        goto RESET unless @inodes;    # start over if we've hit an empty dir

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
    $num ||= $MIN_QUEUE_SIZE;

    my $len = @$queue;

    for (my $i=@$queue; $i < $num; $i++) {
        push @$queue, _get_random_mp3($dirs);
    }

    return @$queue - $len;
}

sub _print_queue {
    my ($queue) = @_;

    # yes.  we WILL start counting from zero.
    my $i = 0;
    print map { $i++ . ": $_\n" } @$queue;
}

sub _print_help {
    print <<__HELP__;
    next:   stop the current track and go to the next one.

    stop/start:
            pause/unpause the player in the current track.

    quit:   quit.

    list/queue:
            show the queue.

    remove [#|head|start|tail|end]:
            remove an item from the queue.  Defaults to head.

    add [#|head|start|tail|end] <file>:
            add an item to the queue at the given position.  Defaults to
            the end (like push).

    play <file>:
            immediately play file.

    clear:  clear and refill the queue.

    info:   information about the currently playing song.

    scrobble [session key|off]:
            turn scrobbling on and off.  Right now session keys need to
            be generated manually.

    Everything else goes straight to mpg123
__HELP__
}

sub _remove_from_queue {
    my ($queue, $args) = @_;

    $args->[0] ||= 0;
    $args->[0] = lc($args->[0]);
    $args->[0] =  0 if $args->[0] eq 'head' or $args->[0] eq 'start';
    $args->[0] = -1 if $args->[0] eq 'tail' or $args->[0] eq 'end';
    $args->[0] = -1 if $args->[0] > @$queue;

    my $removed = splice @$queue, $args->[0], 1;
    print "removed $removed\n";
}

sub _add_to_queue {
    my ($queue, $args) = @_;

    if (@$args == 0) {
        print "=> 'add' needs a filename!\n";
        return;
    }

    my $pos = -1;
    if ($args->[0] =~ m/^(?:head|tail|\d+)$/i) {
        $pos = lc(shift(@$args));
        $pos =  0 if $pos eq 'head' or $pos eq 'start' ;
        $pos = -1 if $pos eq 'tail' or $pos eq 'end';
    }

    my $filename = join(" ", @$args);
    if (not -f $filename) {
        print "=> $filename is not a file!\n";
        return;
    }

    if    ($pos == -1) { push @$queue, $filename; }
    elsif ($pos ==  0) { unshift @$queue, $filename; }
    else { splice @$queue, $pos, 0, $filename; }
}

# play an mp3.  note that last_fm_sk is sent as a reference so we can clear
# it out if there's a scrobbling error.  Ya, we could clear out %mp3_info
# here, too, but we don't for clarity.
sub _mpg123_play {
    my ($track, $mpg123_in, $lastfm_sk_ref, $mp3_info) = @_;

    # scrobble the last track played.  the last two requirements
    # (> 30 seconds and at least 1/2 played or > 240 seconds)
    # are from the Last.fm submissions spec.
    if ($$lastfm_sk_ref and
        $mp3_info->{ARTIST} and $mp3_info->{TITLE} and
        $mp3_info->{MPG123_FRAME_INFO}->[2] > 30 and
        (($mp3_info->{MPG123_FRAME_INFO}->[2] > 
            $mp3_info->{MPG123_FRAME_INFO}->[3]) or
          $mp3_info->{MPG123_FRAME_INFO}->[2] > 240))
    {
        my $ret = $lastfm->call_auth('track.scrobble',
            $$lastfm_sk_ref,
            artist => $mp3_info->{ARTIST},
            track  => $mp3_info->{TITLE},
            timestamp => time(),);

        print "ERROR w/ track.scrobble!  Clearing the session key.\n".
            $ret->decoded_content() and $$lastfm_sk_ref = undef
            unless $ret->is_success();
    }

    print "playing $track\n";
    print $mpg123_in "load $track\n";

    return (FILENAME => $track, SCROBBLED => 0, ARTIST => '', TITLE => '');
}

sub _print_mp3_info {
    my ($mp3_info) = @_;

    print "ARTIST: $mp3_info->{ARTIST}\nTITLE : $mp3_info->{TITLE}\n";
    print "ALBUM : $mp3_info->{ALBUM}" .
          ($mp3_info->{YEAR} ? " ($mp3_info->{YEAR})" : "") . "\n"
          if $mp3_info->{ALBUM};

    print "MPG123_FRAME_INFO: @{$mp3_info->{MPG123_FRAME_INFO}}\n"
        if $mp3_info->{MPG123_FRAME_INFO};
}

