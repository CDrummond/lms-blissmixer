package Plugins::BlissMixer::Settings;

#
# LMS Bliss Mixer
#
# (c) 2022-2026 Craig Drummond
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
    return ($prefs, 'host mixer_port', 'filter_genres', 'filter_xmas', 'min_duration', 'max_duration',
                    'no_repeat_artist', 'no_repeat_album', 'no_repeat_track', 'dstm_tracks', 'genre_groups',
                    'weight_tempo', 'weight_timbre', 'weight_loudness', 'weight_chroma', 'max_bpm_diff',
                    'use_track_genre', 'run_analyser_after_scan', 'analysis_read_tags', 'analysis_write_tags',
                    'use_forest', 'analyser_ignore_dirs', 'analyser_max_files', 'analyser_max_threads',
                    'analyser_ignore_txt', 'match_all_genres');
}

sub beforeRender {
    my ($class, $paramRef) = @_;
    $paramRef->{'server_auth'} = $serverprefs->get('authorize');
    my $host = $paramRef->{host} || (Slim::Utils::Network::serverAddr() . ':' . $serverprefs->get('httpport'));
    $paramRef->{'jsonrpc_url'} = "http://${host}/jsonrpc.js";
    $paramRef->{'start_analysis_text'} = string('BLISSMIXER_ANALYSE_START_BUTTON');
    $paramRef->{'stop_analysis_text'} = string('BLISSMIXER_ANALYSE_ABORT_BUTTON');
    $paramRef->{'update_ignore_now_text'} = string('BLISSMIXER_ANALYSE_IGNORE_BUTTON');
    $paramRef->{'analysed_tracks_text'} = string('BLISSMIXER_ANALYSED_TRACKS');
    $paramRef->{'failed_tracks_text'} = string('BLISSMIXER_FAILED_TRACKS');
    $paramRef->{'ignored_tracks_text'} = string('BLISSMIXER_IGNORED_TRACKS');
    $paramRef->{'analysis_status_text'} = string('BLISSMIXER_ANALYSIS_STATUS');
    $paramRef->{'analysis_start_text'} = string('BLISSMIXER_ANALYSIS_START_TIME');
    $paramRef->{'analysis_duration_text'} = string('BLISSMIXER_ANALYSIS_DURATION');
    $paramRef->{'analysis_download_csv_text'} = string('BLISSMIXER_DOWNLOAD_CSV');
    $paramRef->{'clear_failures_text'} = string('BLISSMIXER_ANALYSE_CLEAR_FAILURES_BUTTON');
    my $analyserBinary = Slim::Utils::Misc::findbin('bliss-analyser');
    $paramRef->{'no_analyser_binary'} = !$analyserBinary;
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
