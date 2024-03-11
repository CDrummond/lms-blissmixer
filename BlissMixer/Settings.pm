package Plugins::BlissMixer::Settings;

#
# LMS Bliss Mixer
#
# (c) 2022-2023 Craig Drummond
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.blissmixer',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.blissmixer');
my $serverprefs = preferences('server');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('BlissMixer');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/BlissMixer/settings/blissmixer.html');
}

sub prefs {
	return ($prefs, 'host mixer_port', 'filter_genres', 'filter_xmas', 'min_duration', 'max_duration', 'no_repeat_artist', 'no_repeat_album', 'no_repeat_track', 'dstm_tracks', 'genre_groups', 'weight_tempo', 'weight_timbre', 'weight_loudness', 'weight_chroma', 'max_bpm_diff');
}

sub beforeRender {
    my ($class, $paramRef) = @_;
    $paramRef->{allowPortConfig} = $serverprefs->get('authorize');
}


sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	return $class->SUPER::handler($client, $params);
}

1;

__END__
