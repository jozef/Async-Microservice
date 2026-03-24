#! /usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::Most;
use Log::Any::Test;    # must come before loading the module under test
use Log::Any qw($log);
use HTTP::Headers;
use FindBin     qw($Bin);
use Path::Class qw(dir);

use_ok('Async::MicroserviceReq') or die;

# Minimal stub for the required 'params' Object attribute.
my $fake_params = bless {}, 'FakeParams';

# Factory: build a minimal MicroserviceReq with controlled headers.
# 'using_frontend_proxy' is extracted and passed as its own constructor
# arg; every other key/value pair becomes an HTTP header.
sub make_req {
    my (%args) = @_;
    my $using_fp = delete $args{using_frontend_proxy} // 0;
    return Async::MicroserviceReq->new(
        method               => 'GET',
        headers              => HTTP::Headers->new(%args),
        path                 => '/v1/test',
        content              => '',
        params               => $fake_params,
        static_dir           => dir($Bin),
        jsonp                => '',
        using_frontend_proxy => $using_fp,
    );
}

subtest '_build_base_url()' => sub {

    subtest 'no proxy (default)' => sub {
        is( make_req()->base_url, '/',
            'returns relative / when using_frontend_proxy is off',
        );
    };

    subtest 'proxy enabled but no forwarded-host headers' => sub {
        $log->clear();
        my $req = make_req( using_frontend_proxy => 1 );
        is( $req->base_url, '/',
            'falls back to relative / when host headers are absent',
        );
        my @warns = grep {
                   $_->{level}   =~ /^warn/
                && $_->{message} =~ /no host information in headers/
        } @{ $log->msgs };
        ok( scalar(@warns), 'emits warning about missing proxy headers' );
    };

    subtest 'plain HTTP with X-Forwarded-Host' => sub {
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'example.com',
        );
        is( $req->base_url, 'http://example.com/', 'basic HTTP URL' );
    };

    subtest 'default port 80 is omitted from HTTP URL' => sub {
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'example.com',
            HTTP_X_FORWARDED_PORT => '80',
        );
        is( $req->base_url, 'http://example.com/', 'port 80 not in URL' );
    };

    subtest 'non-standard port embedded in X-Forwarded-Host' => sub {
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'example.com:8080',
        );
        is( $req->base_url, 'http://example.com:8080/',
            'port from Host header value included',
        );
    };

    subtest 'port in X-Forwarded-Host is not duplicated in URL' => sub {

        # Regression test: before the fix $host still carried :8080 so the
        # URL was assembled as example.com:8080:8080.
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'example.com:8080',
        );
        unlike( "${\$req->base_url}", qr/:\d+:\d+/,
            'port appears exactly once in URL',
        );
    };

    subtest 'non-standard port via X-Forwarded-Port header' => sub {
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'example.com',
            HTTP_X_FORWARDED_PORT => '8080',
        );
        is( $req->base_url, 'http://example.com:8080/',
            'port from X-Forwarded-Port included',
        );
    };

    subtest 'HTTPS via X-Forwarded-Https: ON' => sub {
        my $req = make_req(
            using_frontend_proxy   => 1,
            HTTP_X_FORWARDED_HOST  => 'example.com',
            HTTP_X_FORWARDED_HTTPS => 'ON',
        );
        is( $req->base_url, 'https://example.com/', 'https via Https: ON' );
    };

    subtest 'HTTPS via X-Forwarded-Https: on (lowercase)' => sub {
        my $req = make_req(
            using_frontend_proxy   => 1,
            HTTP_X_FORWARDED_HOST  => 'example.com',
            HTTP_X_FORWARDED_HTTPS => 'on',
        );
        is( $req->base_url, 'https://example.com/',
            'https scheme is case-insensitive for Https header',
        );
    };

    subtest 'HTTPS via X-Forwarded-Proto: https (Pound)' => sub {
        my $req = make_req(
            using_frontend_proxy   => 1,
            HTTP_X_FORWARDED_HOST  => 'example.com',
            HTTP_X_FORWARDED_PROTO => 'https',
        );
        is( $req->base_url, 'https://example.com/',
            'https scheme from X-Forwarded-Proto: https',
        );
    };

    subtest 'default port 443 is omitted from HTTPS URL' => sub {
        my $req = make_req(
            using_frontend_proxy   => 1,
            HTTP_X_FORWARDED_HOST  => 'example.com',
            HTTP_X_FORWARDED_HTTPS => 'ON',
            HTTP_X_FORWARDED_PORT  => '443',
        );
        is( $req->base_url, 'https://example.com/', 'port 443 not in URL' );
    };

    subtest 'HTTPS with non-standard port' => sub {
        my $req = make_req(
            using_frontend_proxy   => 1,
            HTTP_X_FORWARDED_HOST  => 'example.com:8443',
            HTTP_X_FORWARDED_HTTPS => 'ON',
        );
        is( $req->base_url, 'https://example.com:8443/',
            'non-standard HTTPS port included',
        );
    };

    subtest 'X-Forwarded-Host takes precedence over X-Forwarded-Server' =>
        sub {
        my $req = make_req(
            using_frontend_proxy    => 1,
            HTTP_X_FORWARDED_HOST   => 'public.example.com',
            HTTP_X_FORWARDED_SERVER => 'internal.proxy.local',
        );
        is( $req->base_url, 'http://public.example.com/',
            'X-Forwarded-Host wins as the public hostname',
        );
        };

    subtest 'port from X-Forwarded-Server used when Host has none' => sub {

        # Apache sets X-Forwarded-Server with the internal port; the public
        # hostname still comes from X-Forwarded-Host.
        my $req = make_req(
            using_frontend_proxy    => 1,
            HTTP_X_FORWARDED_HOST   => 'public.example.com',
            HTTP_X_FORWARDED_SERVER => 'internal.proxy.local:8080',
        );
        is( $req->base_url,
            'http://public.example.com:8080/',
            'port from X-Forwarded-Server carried through to URL',
        );
    };

    subtest 'last entry wins for comma-separated X-Forwarded-Host' => sub {
        my $req = make_req(
            using_frontend_proxy  => 1,
            HTTP_X_FORWARDED_HOST => 'proxy1.internal, example.com',
        );
        is( $req->base_url, 'http://example.com/',
            'rightmost host in X-Forwarded-Host chain is used',
        );
    };

};

done_testing();
