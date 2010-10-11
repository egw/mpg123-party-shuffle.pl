
package LWP::UserAgent::LastFM;

# http://search.cpan.org/~lbrocard/Net-LastFM-0.34/lib/Net/LastFM.pm
# http://easyclasspage.de/lastfm/seite-11.html

use warnings;
use strict;

use base qw(LWP::UserAgent);

use Digest::MD5 qw(md5_hex);
use URI::QueryParam;

my $lastfm_service_root = 'http://ws.audioscrobbler.com/2.0/';

sub new {
    my ($class, $key, $secret) = @_;
    my $self = $class->SUPER::new();

    $self->agent('Yet-Another-LastFM-Perl-Module/0.001gamma');

    bless($self, $class);
}

sub call {
    my ($self, $method, %params) = @_;

    warn "API key and secret not set!  Aborting call($method, ....)"
        and return
        unless $self->{api_key} and $self->{api_secret};

    $params{method} = $method;

    $params{api_key} = $self->{api_key};
    $params{api_sig} = md5_hex(
        join("", map { $_ . $params{$_} }
                 sort grep {lc($_) ne 'format' and lc($_) ne 'callback'}
                 keys %params).
        $self->{api_secret});

    # temporarily redirect scrobbling requests to post.audioscrobbler.com
    # see http://users.last.fm/~tims/Scrobbling2_0_beta_docs.html
    my $service_root = $lastfm_service_root;
    if (lc($method) eq 'user.updatenowplaying' or
        lc($method) eq 'track.scrobble' or
        lc($method) eq 'track.scrobblebatch')
    { $service_root = 'http://post.audioscrobbler.com/2.0/'; }

    my $uri = URI->new($service_root);
    while (my ($k, $v) = each(%params)) {
        $uri->query_param($k => $v);
    }

    my $response = exists($params{sk}) ? $self->post($uri) : $self->get($uri);
}

sub call_auth {
    my ($self, $method, $sk, %params) = @_;
    $params{sk} = $sk;

    $self->call($method, %params);
}

sub key { my $self = shift(); return @_ ? $self->{api_key} = shift() : $self->{api_key}; }
sub api_key { my $self = shift(); return @_ ? $self->{api_key} = shift() : $self->{api_key}; }
sub secret { my $self = shift(); return @_ ? $self->{api_secret} = shift() : $self->{api_secret}; }
sub api_secret { my $self = shift(); return @_ ? $self->{api_secret} = shift() : $self->{api_secret}; }

sub get_authorization_url {
    my ($self) = @_;

    my $response = $self->call('auth.getToken');
    my ($token) = ($response->decoded_content() =~ m/<token>([^<]*?)<\/token>/);
    $self->{token} = $token;

    return "http://www.last.fm/api/auth/?api_key=$self->{api_key}&token=$token";
}

sub get_session_key {
    my ($self, $token) = @_;

    $token ||= $self->{token};

    my $response = $self->call('auth.getSession', token => $token);
    my ($sk) = ($response->decoded_content() =~ m/<key>([^<]*?)<\/key>/);

    return $sk;
}

1;


=pod

=head1 NAME

LWP::UserAgent::LastFM - a(nother) simple interface to the Last.fm API

=head1 SYNOPSIS

 my $api = LWP::UserAgent::LastFM->new();
 $api->key( API_KEY );
 $api->secret( API_SECRET );

 my $response = $api->call($method, %params);

 my $reponse = $api->call_auth($method, $session_key, %params);

=head1 DESCRIPTION

Based on Klaus Tockloth's lmdCMD.pl at
http://easyclasspage.de/lastfm/seite-11.html but implemented as a subclass
of LWP::UserAgent.

=head1 METHODS

=over 4

=item new([$api_key], [$api_secret])

=item call($method, %params)

Call an API method.

=item call_auth($method, $session_key, %params)

Call an authenticated API method.

=back

=head1 OTHER METHODS

=over 4

=item get_authorization_url()

Get an authorization url.  The user should go here and authorize the
application.

=item get_session_key([$token])

Return the session key associated with the given token.  This should be
called after the user authorizes the app on the web site.

=back

=head1 TODO

=cut

