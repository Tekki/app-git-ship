package App::git::ship::perl;

=head1 NAME

App::git::ship::perl - Ship your Perl module

=head1 DESCRIPTION

L<App::git::ship::perl> is a module that can ship your Perl module.

See L<App::git::ship/SYNOPSIS>

=cut

use App::git::ship -base;
use Cwd ();
use File::Basename ();
use File::Spec;
use Module::CPANfile;

my $VERSION_RE = qr{\d+\.[\d_]+};

=head1 ATTRIBUTES

=head2 main_module_path

  $str = $self->main_module_path;

Tries to guess the path to the main module in the repository. This is done by
looking at the repo name and try to find a file by that name. Example:

  ./my-cool-project/.git
  ./my-cool-project/lib/My/Cool/Project.pm

This guessing is case-insensitive.

Instead of guessing, you can put "main_module_path" in the config file.

=cut

has main_module_path => sub {
  my $self = shift;
  return $self->config->{main_module_path} if $self->config->{main_module_path};

  my @path = split /-/, File::Basename::basename(Cwd::getcwd);
  my $path = 'lib';
  my @name;

  PATH_PART:
  for my $p (@path) {
    opendir my $DH, $path or $self->abort("Cannot find project name from $path: $!");

    for my $f (readdir $DH) {
      $f =~ s/\.pm$//;
      next unless lc $f eq lc $p;
      push @name, $f;
      $path = File::Spec->catdir($path, $f);
      next PATH_PART;
    }
  }

  return "$path.pm";
};

=head2 project_name

  $str = $self->project_name;

Tries to figure out the project name from L</main_module_path> unless the
L</project_name> is specified in config file.

Example result: "My::Perl::Project".

=cut

has project_name => sub {
  my $self = shift;

  return $self->config->{project_name} if $self->config->{project_name};

  my @name = File::Spec->splitdir($self->main_module_path);
  shift @name if $name[0] eq 'lib';
  $name[-1] =~ s!\.pm$!!;
  join '::', @name;
};

has _cpanfile => sub { Module::CPANfile->load; };

=head1 METHODS

=head2 build

Used to build a Perl distribution.

=cut

sub build {
  my $self = shift;

  $self->clean(0);
  $self->_generate_makefile;
  $self->_timestamp_to_changes;
  $self->_update_version_info;
  $self->system(sprintf '%s %s > %s', 'perldoc -tT', $self->main_module_path, 'README');
  $self->system(qw( git commit -a -m ), $self->_changes_to_commit_message);
  $self->_make('manifest');
  $self->_make('dist');
  $self;
}

=head2 can_handle_project

See L<App::git::ship/can_handle_project>.

=cut

sub can_handle_project {
  my ($class, $app) = @_;
  my $can_handle_project = 0;

  if (-d 'lib') {
    File::Find::find(sub { $can_handle_project = 1 if /\.pm$/; }, 'lib');
  }

  return $can_handle_project;
}

=head2 clean

Used to clean out build files.

=cut

sub clean {
  my $self = shift;
  my $all = shift // 1;
  my @files = qw(
    Makefile
    Makefile.old
    MANIFEST
    MYMETA.json
    MYMETA.yml
  );

  if ($all) {
    push @files, qw(
      Changes.bak
      META.json
      META.yml
    );
  }

  for my $file (@files) {
    unlink $file if -e $file;
  }
}

=head2 init

Used to generate C<Changes> and C<MANIFEST.SKIP>.

=cut

sub init {
  my $self = shift;

  symlink $self->main_module_path, 'README.pod' unless -e 'README.pod';

  $self->SUPER::init(@_);
  $self->_generate_changes;
  $self->_generate_manifest_skip;
  $self;
}

=head2 ship

Use L<App::git::ship/ship> and then push the new release to CPAN
using C<cpan-uploader-http>.

=cut

sub ship {
  my $self = shift;
  my $uploader = CPAN::Uploader->new(CPAN::Uploader->read_config_file);
  my $dist_file = $self->_dist_files(sub { 1 });

  unless ($dist_file) {
    $self->abort("Build process failed.") unless $self->{ship_retry}++;
    $self->build->ship(@_);
    return;
  }

  $self->SUPER::ship(@_);
  $uploader->upload_file($dist_file);
  $self;
}

sub _author {
  my $self = shift;
  my $format = shift || '%an';

  open my $GIT, '-|', qw( git log ), "--format=$format" or $self->abort("git log --format=$format: $!");
  my $author = readline $GIT;
  chomp $author;
  warn "[ship::author] $format = $author\n" if DEBUG;
  return $author;
}

sub _changes_to_commit_message {
  my $self = shift;
  my $message = '';
  my $version;

  local @ARGV = qw( Changes );
  while (<>) {
    $message .= $_ if /^($VERSION_RE)\s+/ .. $message && /^$VERSION_RE\s+/;
    $version = $1 if $1;
  }

  $message =~ s!.*\n!Released version $version\n\n!;
  $message;
}

sub _dist_files {
  my ($self, $cb) = @_;
  my $name = lc($self->project_name) =~ s!::!-!gr;

  opendir(my $DH, Cwd::getcwd);
  while (readdir $DH) {
    next unless /^$name.*\.tar/i;
    return $_ if $self->$cb;
  }

  return undef;
}

sub _generate_changes {
  my $self = shift;

  return if -e 'Changes';
  open my $CHANGES, '>', 'Changes' or $self->abort("Could not write to ./Changes: $!");
  print $CHANGES <<"CHANGES";
Changelog for @{[$self->project_name]}

0.01
       * Started project

CHANGES
}

sub _generate_makefile {
  my $self = shift;
  my $prereqs = $self->_cpanfile->prereqs;
  my $args = {};

  $args->{ABSTRACT_FROM} = $self->main_module_path;
  $args->{AUTHOR} = $self->_author('%an <%ae>');
  $args->{LICENSE} = $self->config->{license};
  $args->{NAME} = $self->project_name;
  $args->{VERSION_FROM} = $self->main_module_path;
  $args->{test} = { TESTS => 't/*.t' };

  $args->{META_MERGE} = {
    resources => {
      bugtracker => $self->config->{bugtracker},
      homepage => $self->config->{homepage},
      repository => $self->repository,
    },
  };

  $args->{PREREQ_PM} = $prereqs->requirements_for(qw( runtime requires ))->as_string_hash;

  for my $k (qw( build test )) {
    my $r = $prereqs->requirements_for($k, 'requires')->as_string_hash;
    $args->{BUILD_REQUIRES}{$_} = $r->{$_} for keys %$r;
  }

  $args = Data::Dumper->new([$args])->Indent(1)->Terse(1)->Sortkeys(1)->Dump;
  $args =~ s!{\n?!!s;
  $args =~ s!\n?}\n?$!!s;

  open my $MAKEFILE, '>', 'Makefile.PL' or $self->abort("Write Makefile.PL: $!");
  print $MAKEFILE "use ExtUtils::MakeMaker;\nWriteMakefile(\n$args\n);\n";
}

sub _generate_manifest_skip {
  my $self = shift;

  return if -e 'MANIFEST.SKIP';
  open my $SKIP, '>', 'MANIFEST.SKIP' or $self->abort("Could not write to ./MANIFEST.SKIP: $!");
  print $SKIP <<'MANIFEST_SKIP';
.git
\.old
\.swp
~$
^blib/
^cover_db/
^local/
^Makefile$
^MANIFEST.*
^MYMETA*
^README.pod
MANIFEST_SKIP
}

sub _make {
  my ($self, @args) = @_;

  $self->_generate_makefile unless -e 'Makefile.PL';
  $self->system(perl => 'Makefile.PL') unless -e 'Makefile';
  $self->system(make => @args);
}

sub _timestamp_to_changes {
  my $self = shift;
  my $date = localtime;

  local @ARGV = qw( Changes );
  local $^I = '';
  while (<>) {
    $self->{next_version} = $1 if s/^($VERSION_RE)\s*/{ sprintf "\n%-7s  %s\n", $1, $date }/e;
    print; # print back to same file
  }

  $self->abort('Unable to add timestamp to ./Changes') unless $self->{next_version};
}

sub _update_version_info {
  my $self = shift;
  my $version = $self->{next_version} or $self->abort('Internal error: Are you sure Changes has a timestamp?');

  local @ARGV = ($self->main_module_path);
  local $^I = '';
  while (<>) {
    s/$VERSION_RE/$version/ if /^=head1 VERSION/ .. /^=head1/;
    s/((?:our)?\s*\$VERSION)\s*=.*$/$1 = '$version';/;
    print; # print back to same file
  }
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
