# Bliss Mixer

LMS `Don't Stop The Music` plugin using [Bliss Mixer](https://github.com/CDrummond/bliss-mixer)
to provide random tracks similar to seed tracks chosen from the current play
queue.

[Bliss Mixer](https://github.com/CDrummond/bliss-mixer) requires that your music
is first analysed with [Bliss Analyser](https://github.com/CDrummond/bliss-analyser)


# LMS Menus

A `Create bliss mix` entry is added to the `More`/context menus in LMS. This
creates a mix of tracks based upon the selected artist, album, or track,
returned in a shuffled order. Up to 50 tracks are returned for artists or
albums, and up to 20 for tracks.

*NOTE* This menu entry does not currently work with the `Default` LMS web skin,
but does work with `Material Skin` and other controllers.
