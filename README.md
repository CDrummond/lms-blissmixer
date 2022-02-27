# Bliss Mixer

LMS `Don't Stop The Music` plugin using [Bliss Mixer](https://github.com/CDrummond/bliss-mixer)
to provide random tracks similar to seed tracks chosen from the current play
queue.

[Bliss Mixer](https://github.com/CDrummond/bliss-mixer) requires that your music
is first analysed with [Bliss Analyser](https://github.com/CDrummond/bliss-analyser)


# LMS Menus

3 entries are added to LMS' 'More'/context menus:

1. `Similar tracks` returns (up to) 50 tracks that are similar to the selected
track, returned in similarity order.
2. `Similar tracks by artist` returns (up to) 50 by the same artist that are
similar to the selected track, returned in similarity order.
3. `Create bliss mix` creates a mix of (up to) 50 tracks based upon the selected
artist, album, or track, returned in a shuffled order.

*NOTE* These menus do not currently work with the `Default` LMS web skin, but do
work with `Material Skin` and other controllers.

