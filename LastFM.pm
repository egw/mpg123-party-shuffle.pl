
package LWP::UserAgent::LastFM;

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
    $self->{api_key} = $self->{api_secret} = undef;

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

    my $uri = URI->new($lastfm_service_root);
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

######################################################################
######################################################################
######################################################################
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
http://easyclasspage.de/lastfm/seite-11.html, but implemented as a
subclass of LWP::UserAgent.

=head1 METHODS

In addition to the methods inherited from LWP::UserAgent, the LastFM
subclass defines or overrides these methods.

=over 4

=item new([$api_key], [$api_secret])

Constructor.

=item call($method, %params)

Call an API method.  All calls are signed.  Returns the HTTP::Response
of the method call.

=item call_auth($method, $session_key, %params)

Call an authenticated API method.

=item api_key([$api_key])

=item key([$api_key])

Get/set the api key.  This is public and sent with each request.

=item api_secret([$api_secret])

=item secret([$api_secret])

Get/set the api secret.  This is private and is never sent back
to Last.fm.

=back

=head1 CONVENIENCE METHODS

=over 4

=item get_authorization_url( )

Get an authorization url.  The user needs to go to this url in order to
authorize the application.

=item get_session_key([$token])

Return the session key associated with the given token.  This should be
called after the user authorizes the app on the web site.

If $token is not passed, this uses the $token received by
get_authorization_url().  This is a little sketchy because one has to
make sure the LastFM instance that's asking for the token is the same one
that got the authorization url.  This might not be true in a stateless
client/server (i.e. web-like) setting where a client might connect to a
different server for every request; or a single server might get requests
from multiple clients.

To be safe, one should probably explicitly set $token all of the time.

=back

=head1 TODO

stuff

=head1 REFERENCE

=over 4

=item http://www.last.fm/api/intro

=item http://easyclasspage.de/lastfm/seite-11.html

=item http://search.cpan.org/~lbrocard/Net-LastFM-0.34/lib/Net/LastFM.pm

=back

=head1 SEE ALSO

HTTP::Response.  I guess LWP and LWP::UserAgent if you want to use this
as a more general user agent, too.

=head1 LICENSE

Copyright (c) 2010, Eric Wong <eric@taedium.com>

This module is free software; you can redistribute it or modify it under
the same terms as Perl itself.


=cut

