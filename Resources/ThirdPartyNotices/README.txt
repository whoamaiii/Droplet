Droplet — third-party software

Droplet runs these separate programs, which are included unmodified in
Droplet.app/Contents/Helpers. Each is distributed under its own license; the
license texts are in this folder, and SOURCES.txt lists where to obtain the
corresponding source code for the exact versions included.

  yt-dlp   (Contents/Helpers/yt-dlp)
           The standalone macOS build. yt-dlp itself is released under the
           Unlicense; the standalone build bundles Python and other components
           and is distributed as a whole under the GNU GPL v3 or later.
           See yt-dlp-LICENSE.txt.

  FFmpeg   (Contents/Helpers/ffmpeg, Contents/Helpers/ffprobe)
           Used only to combine video and audio without re-encoding.
           Licensed under the GNU LGPL or GPL depending on the build; see
           ffmpeg-LICENSE.txt.

  Deno     (Contents/Helpers/deno)
           JavaScript runtime used by yt-dlp for YouTube. MIT License; see
           deno-LICENSE.txt.

These programs are invoked as independent processes. Droplet's own code is
not a derivative of them. To obtain the source code for any of them, use the
links in SOURCES.txt or contact the publisher listed on the Droplet website;
a copy will be provided for at least three years after you received Droplet.

Droplet is not affiliated with or endorsed by the yt-dlp, FFmpeg or Deno
projects. Only download videos you have the right to download.
