use lib '.';
use t::Util;
use App::git::ship;

$ENV{GIT_SHIP_CONFIG} = File::Spec->catfile(qw(t data with-comments.conf));
plan skip_all => "Cannot read $ENV{GIT_SHIP_CONFIG}" unless -r $ENV{GIT_SHIP_CONFIG};

my $app = App::git::ship->new;

is $app->config->{foo}, '123', 'config foo';
is $app->config('bar'), '## does this work', 'config bar';

is $app->config('whatever'), '', 'whatever';
$ENV{GIT_SHIP_WHATEVER} = 'cool';
is $app->config('whatever'), 'cool', 'GIT_SHIP_WHATEVER';

done_testing;
