package Catalyst::Plugin::ConfigLoader;

use strict;
use warnings;

use Config::Any;
use NEXT;
use Data::Visitor::Callback;
use Catalyst::Utils ();

our $VERSION = '0.16';

=head1 NAME

Catalyst::Plugin::ConfigLoader - Load config files of various types

=head1 SYNOPSIS

    package MyApp;
    
    # ConfigLoader should be first in your list so
    # other plugins can get the config information
    use Catalyst qw( ConfigLoader ... );
    
    # by default myapp.* will be loaded
    # you can specify a file if you'd like
    __PACKAGE__->config( file => 'config.yaml' );    

=head1 DESCRIPTION

This module will attempt to load find and load a configuration
file of various types. Currently it supports YAML, JSON, XML,
INI and Perl formats.

To support the distinction between development and production environments,
this module will also attemp to load a local config (e.g. myapp_local.yaml)
which will override any duplicate settings.

=head1 METHODS

=head2 setup( )

This method is automatically called by Catalyst's setup routine. It will
attempt to use each plugin and, once a file has been successfully
loaded, set the C<config()> section. 

=cut

sub setup {
    my $c     = shift;
    my @files = $c->find_files;
    my $cfg   = Config::Any->load_files( {
        files   => \@files, 
        filter  => \&_fix_syntax,
        use_ext => 1
    } );

    # split the responses into normal and local cfg
    my $local_suffix = $c->get_config_local_suffix;
    my( @cfg, @localcfg );
    for( @$cfg ) {
        if( ( keys %$_ )[ 0 ] =~ m{ $local_suffix \. }xms ) {
            push @localcfg, $_;
        } else {
            push @cfg, $_;
        }
    }
    
    # load all the normal cfgs, then the local cfgs last so they can override
    # normal cfgs
    $c->load_config( $_ ) for @cfg, @localcfg;

    $c->finalize_config;
    $c->NEXT::setup( @_ );
}

=head2 load_config

This method handles loading the configuration data into the Catalyst
context object. It does not return a value.

=cut

sub load_config {
    my $c   = shift;
    my $ref = shift;
    
    my( $file, $config ) = each %$ref;
    
    $c->config( $config );
    $c->log->debug( qq(Loaded Config "$file") )
        if $c->debug;

    return;
}

=head2 find_files

This method determines the potential file paths to be used for config loading.
It returns an array of paths (up to the filename less the extension) to pass to
L<Config::Any|Config::Any> for loading.

=cut

sub find_files {
    my $c = shift;
    my( $path, $extension ) = $c->get_config_path;
    my $suffix     = $c->get_config_local_suffix;
    my @extensions = @{ Config::Any->extensions };
    
    my @files;
    if ($extension) {
        next unless grep { $_ eq $extension } @extensions;
        push @files, $path, "${path}_${suffix}";
    } else {
        @files = map { ( "$path.$_", "${path}_${suffix}.$_" ) } @extensions;
    }

    @files;
}

=head2 get_config_path

This method determines the path, filename prefix and file extension to be used
for config loading. It returns the path (up to the filename less the
extension) to check and the specific extension to use (if it was specified).

The order of preference is specified as:

=over 4

=item * C<$ENV{ MYAPP_CONFIG }>

=item * C<$ENV{ CATALYST_CONFIG }>

=item * C<$c-E<gt>config-E<gt>{ 'Plugin::ConfigLoader' }-E>gt>{ file }>

=item * C<$c-E<gt>path_to( $application_prefix )>

=back

If either of the first two user-specified options are directories, the
application prefix will be added on to the end of the path.

DEPRECATION NOTICE: C<$c-E<gt>config-E<gt>{ file }> is deprecated
and will be removed in the next release.

=cut

sub get_config_path {
    my $c       = shift;
    my $appname = ref $c || $c;
    my $prefix  = Catalyst::Utils::appprefix( $appname );
    my $path    = Catalyst::Utils::env_value( $c, 'CONFIG' )
        || $c->config->{ 'Plugin::ConfigLoader' }->{ file }
        || $c->config->{ file } # to be removed next release
        || $c->path_to( $prefix );

    my( $extension ) = ( $path =~ m{\.(.{1,4})$} );
    
    if( -d $path ) {
        $path  =~ s{[\/\\]$}{};
        $path .= "/$prefix";
    }
    
    return( $path, $extension );
}

=head2 get_config_local_suffix

Determines the suffix of files used to override the main config. By default
this value is C<local>, but it can be specified in the following order of preference:

=over 4

=item * C<$ENV{ MYAPP_CONFIG_LOCAL_SUFFIX }>

=item * C<$ENV{ CATALYST_CONFIG_LOCAL_SUFFIX }>

=item * C<$c-E<gt>config-E<gt>{ 'Plugin::ConfigLoader' }-E<gt>{ config_local_suffix }>

=back

DEPRECATION NOTICE: C<$c-E<gt>config-E<gt>{ config_local_suffix }> is deprecated
and will be removed in the next release.

=cut

sub get_config_local_suffix {
    my $c       = shift;
    my $appname = ref $c || $c;
    my $suffix  = Catalyst::Utils::env_value( $c, 'CONFIG_LOCAL_SUFFIX' )
        || $c->config->{ 'Plugin::ConfigLoader' }->{ config_local_suffix }
        || $c->config->{ config_local_suffix } # to be remove in the next release
        || 'local';

    return $suffix;
}

sub _fix_syntax {
    my $config     = shift;
    my @components = (
        map +{
            prefix => $_ eq 'Component' ? '' : $_ . '::',
            values => delete $config->{ lc $_ } || delete $config->{ $_ }
        },
        grep {
            ref $config->{ lc $_ } || ref $config->{ $_ }
        }
        qw( Component Model M View V Controller C )
    );

    foreach my $comp ( @components ) {
        my $prefix = $comp->{ prefix };
        foreach my $element ( keys %{ $comp->{ values } } ) {
            $config->{ "$prefix$element" } = $comp->{ values }->{ $element };
        }
    }
}

=head2 finalize_config

This method is called after the config file is loaded. It can be
used to implement tuning of config values that can only be done
at runtime. If you need to do this to properly configure any
plugins, it's important to load ConfigLoader before them.
ConfigLoader provides a default finalize_config method which
walks through the loaded config hash and calls the C<config_substitutions>
sub on any string.

=cut

sub finalize_config {
    my $c = shift;
    my $v = Data::Visitor::Callback->new(
        plain_value => sub {
            return unless defined $_;
            $c->config_substitutions( $_ );
        }
    );
    $v->visit( $c->config );
}

=head2 config_substitutions( $value )

This method substitutes macros found with calls to a function. There are three
default macros:

=over 4

=item * C<__HOME__> - replaced with C<$c-E<gt>path_to('')>

=item * C<__path_to(foo/bar)__> - replaced with C<$c-E<gt>path_to('foo/bar')>

=item * C<__literal(__FOO__)__> - leaves __FOO__ alone (allows you to use
C<__DATA__> as a config value, for example)

=back

The parameter list is split on comma (C<,>). You can override this method to
do your own string munging, or you can define your own macros in
C<MyApp-E<gt>config-E<gt>{ 'Plugin::ConfigLoader' }-E<gt>{ substitutions }>.
Example:

    MyApp->config->{ 'Plugin::ConfigLoader' }->{ substitutions } = {
        baz => sub { my $c = shift; qux( @_ ); }
    }

The above will respond to C<__baz(x,y)__> in config strings.

=cut

sub config_substitutions {
    my $c = shift;
    my $subs = $c->config->{ 'Plugin::ConfigLoader' }->{ substitutions } || {};
    $subs->{ HOME } ||= sub { shift->path_to( '' ); };
    $subs->{ path_to } ||= sub { shift->path_to( @_ ); };
    $subs->{ literal } ||= sub { return $_[ 1 ]; };
    my $subsre = join( '|', keys %$subs );

    for ( @_ ) {
        s{__($subsre)(?:\((.+?)\))?__}{ $subs->{ $1 }->( $c, $2 ? split( /,/, $2 ) : () ) }eg;
    }
}


=head1 AUTHOR

Brian Cassidy E<lt>bricas@cpan.orgE<gt>

=head1 CONTRIBUTORS

The following people have generously donated their time to the
development of this module:

=over 4

=item * Joel Bernstein E<lt>rataxis@cpan.orgE<gt> - Rewrite to use L<Config::Any>

=item * David Kamholz E<lt>dkamholz@cpan.orgE<gt> - L<Data::Visitor> integration

=back

Work to this module has been generously sponsored by: 

=over 4

=item * Portugal Telecom L<http://www.sapo.pt/> - Work done by Joel Bernstein

=back

=head1 COPYRIGHT AND LICENSE

Copyright 2007 by Brian Cassidy

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=head1 SEE ALSO

=over 4 

=item * L<Catalyst>

=item * L<Catalyst::Plugin::ConfigLoader::Manual>

=item * L<Config::Any>

=back

=cut

1;
