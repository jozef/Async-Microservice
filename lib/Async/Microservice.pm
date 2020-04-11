package Async::Microservice;

use strict;
use warnings;
use 5.010;
use utf8;

our $VERSION = 0.01;

use Moose::Role;
requires qw(get_routes service_name);

use Plack::Request;
use Try::Tiny;
use Path::Class qw(dir file);
use MooseX::Types::Path::Class;
use Path::Router;
use FindBin qw($Bin);
use Async::MicroserviceReq;

has 'api_version' => (
    is      => 'ro',
    isa     => 'Int',
    default => 1,
);
has 'static_dir' => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    coerce   => 1,
    default  => sub {
        my $static_dir = $ENV{STATIC_DIR} // dir($Bin, '..', 'root', 'static');
        die 'static dir "' . $static_dir . '" not found (check $ENV{STATIC_DIR})'
            if !$static_dir || !-d $static_dir;
        return $static_dir;
    },
    lazy => 1,
);

has 'router' => (
    is      => 'ro',
    isa     => 'Path::Router',
    lazy    => 1,
    builder => '_build_router'
);

our $start_time = time();
our $req_count  = 0;

sub _build_router {
    my ($self) = @_;

    my $router = Path::Router->new;
    my @routes = $self->get_routes();
    while (@routes) {
        my ($path, $opts) = splice(@routes, 0, 2);
        $router->add_route($path, %$opts);
    }

    return $router;
}

sub plack_handler {
    my ($self, $env) = @_;

    $req_count++;

    my $plack_req = Plack::Request->new($env);
    my $this_req  = Async::MicroserviceReq->new(
        method     => $plack_req->method,
        headers    => $plack_req->headers,
        content    => $plack_req->content,
        path       => $plack_req->path_info,
        params     => $plack_req->parameters,
        static_dir => $self->static_dir,
    );

    # set process name and last requested path for debug/troubleshooting
    $0 = $self->service_name . ' ' . $this_req->path;

    my $plack_handler_sub = sub {
        my ($plack_respond) = @_;
        $this_req->plack_respond($plack_respond);

        # API version
        my ($version, $sub_path_info);
        if ($this_req->path =~ qr{^/v(\d+?)(/.*)$}) {
            $version       = $1;
            $sub_path_info = $2;
        }

        # without version path redirect to the latest version
        return $this_req->redirect('/v' . $self->api_version . '/')
            unless $version;

        # handle static/
        return $this_req->static($1)
            if ($sub_path_info =~ qr{^/static(/.+)$});

        # dispatch request
        state $path_dispatch = {
            '/' => sub {
                $this_req->static('index.html', sub {$self->_update_openapi_html(@_)});
            },
            '/edit' => sub {
                $this_req->static('edit.html', sub {$self->_update_openapi_html(@_)});
            },
            '/hcheck' => sub {
                $this_req->text_plain(
                    'Service-Name: ' . $self->service_name,
                    "API-Version: " . $self->api_version,
                    'Uptime: ' . (time() - $start_time),
                    'Request-Count: ' . $req_count,
                    'Pending-Requests: ' . Async::MicroserviceReq->get_pending_req,
                );
            },
            '' => sub {
                if (my $match = $self->router->match($sub_path_info)) {
                    my $func = $match->{mapping}->{$this_req->method};
                    if ($func) {
                        if (my $misc_fn = $self->can($func)) {
                            return $misc_fn->($self, $this_req);
                        }
                    }
                }
                return $this_req->respond(404, [], 'not found');
            },
        };
        my $dispatch_fn = $path_dispatch->{$sub_path_info} // $path_dispatch->{''};

        return $dispatch_fn->();
    };

    return sub {
        my $respond  = shift;
        my $response = try {
            $plack_handler_sub->($respond);
        }
        catch {
            $this_req->respond(503, [], 'internal server error: ' . $_);
        };
        return $response;
    };
}

sub _update_openapi_html {
    my ($self, $content) = @_;
    my $service_name = $self->service_name;
    $content =~ s/ASYNC-SERVICE-NAME/$service_name/g;
    return $content;
}

1;

__END__

=head1 NAME

Async::Microservice - Async HTTP Microservice Moose Role

=head1 SYNOPSYS

    # lib/Async/Microservice/HelloWorld.pm
    package Async::Microservice::HelloWorld;
    use Moose;
    with qw(Async::Microservice);
    sub service_name {return 'asmi-helloworld';}
    sub get_routes {return ('hello' => {defaults => {GET => 'GET_hello'}});}
    sub GET_hello {
        my ($self, $this_req) = @_;
        return $this_req->respond(200, [], 'Hello world!');
    }
    1;

    # bin/async-microservice-helloworld.psgi
    use Async::Microservice::HelloWorld;
    my $mise = Async::Microservice::HelloWorld->new();
    return sub { $mise->plack_handler(@_) };

    $ plackup -Ilib --port 8089 --server Twiggy bin/async-microservice-helloworld.psgi

    $ curl http://localhost:8089/v1/hello
    Hello world!

=head1 DESCRIPTION

This L<Moose::Role> helps to quicly bootstrap async http service that is
including OpenAPI documentation.

See L<https://time.meon.eu/> and the Perl code L<Async::Microservice::Time>.

=head1 SEE ALSO

OpenAPI Specification: L<https://github.com/OAI/OpenAPI-Specification/tree/master/versions>
or L<https://swagger.io/docs/specification/about/>

L<Async::MicroserviceReq>
L<Twiggy>

=head1 TODO

    - graceful termination (finish all requests before terminating on sigterm/hup)
    - systemd service file examples
    - static/index.html and static/edit.html are not really static, should be moved

=head1 CONTRIBUTORS & CREDITS

The following people have contributed to this distribution by committing their
code, sending patches, reporting bugs, asking questions, suggesting useful
advice, nitpicking, chatting on IRC or commenting on my blog (in no particular
order):

    you?

Also thanks to my current day-job-employer L<https://www.apa-it.at/>.

=head1 BUGS

Please report any bugs or feature requests via L<https://github.com/jozef/Async-Microservice/issues>.

=head1 AUTHOR

Jozef Kutej

=head1 COPYRIGHT & LICENSE

Copyright 2020 Jozef Kutej, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut