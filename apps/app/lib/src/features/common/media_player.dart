import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays Thread audio and video from a short-lived signed link (the backend's
/// `media-link`), so the browser or platform player streams it by byte range
/// instead of the app downloading the whole file first.
typedef MediaLinkLoader = Future<Uri> Function(Map<String, dynamic> file);

bool _matches(Map<String, dynamic> file, String prefix, RegExp names) =>
    (file['mediaType']?.toString() ?? '').toLowerCase().startsWith(prefix) ||
    names.hasMatch(file['name']?.toString() ?? '');

bool attachmentIsAudio(Map<String, dynamic> file) => _matches(file, 'audio/',
    RegExp(r'\.(mp3|m4a|aac|wav|ogg|oga|opus|flac)$', caseSensitive: false));

bool attachmentIsVideo(Map<String, dynamic> file) => _matches(
    file, 'video/', RegExp(r'\.(mp4|m4v|mov|webm|ogv)$', caseSensitive: false));

String formatMediaTime(Duration value) {
  final minutes = value.inMinutes;
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Creates the player for a link; replaced in tests.
VideoPlayerController Function(Uri link) mediaControllerFactory =
    (link) => VideoPlayerController.networkUrl(link);

/// Shared loading and failure handling for one file's player.
mixin _MediaController<T extends StatefulWidget> on State<T> {
  VideoPlayerController? controller;
  bool loading = false;
  String? failure;

  Map<String, dynamic> get file;
  MediaLinkLoader get loadLink;

  Future<VideoPlayerController?> ensureController() async {
    if (controller != null) return controller;
    if (loading) return null;
    setState(() {
      loading = true;
      failure = null;
    });
    VideoPlayerController? created;
    try {
      created = mediaControllerFactory(await loadLink(file));
      await created.initialize();
      created.addListener(_changed);
      if (!mounted) {
        await created.dispose();
        return null;
      }
      setState(() => controller = created);
      return created;
    } catch (_) {
      await created?.dispose();
      if (mounted) setState(() => failure = 'This file cannot be played here.');
      return null;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> togglePlay() async {
    final player = await ensureController();
    if (player == null) return;
    final value = player.value;
    if (value.isPlaying) {
      await player.pause();
    } else {
      if (value.duration > Duration.zero && value.position >= value.duration) {
        await player.seekTo(Duration.zero);
      }
      await player.play();
    }
  }

  @override
  void dispose() {
    controller?.removeListener(_changed);
    unawaited(controller?.dispose());
    super.dispose();
  }
}

/// The inside of an audio file card: play/pause, elapsed time and progress.
class AudioAttachmentPlayer extends StatefulWidget {
  const AudioAttachmentPlayer(
      {super.key, required this.file, required this.loadLink});
  final Map<String, dynamic> file;
  final MediaLinkLoader loadLink;

  @override
  State<AudioAttachmentPlayer> createState() => _AudioAttachmentPlayerState();
}

class _AudioAttachmentPlayerState extends State<AudioAttachmentPlayer>
    with _MediaController {
  @override
  Map<String, dynamic> get file => widget.file;
  @override
  MediaLinkLoader get loadLink => widget.loadLink;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = controller?.value;
    final playing = value?.isPlaying ?? false;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    final progress = duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return Semantics(
      label: 'Audio ${widget.file['name'] ?? ''}',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 6),
          Text(widget.file['name']?.toString() ?? 'Audio',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall),
          Expanded(
            child: Center(
              child: failure != null
                  ? Tooltip(
                      message: failure!,
                      child: Icon(Icons.music_off_outlined,
                          color: colors.onSurfaceVariant))
                  : IconButton(
                      key: const ValueKey('audio-play'),
                      tooltip: playing ? 'Pause' : 'Play',
                      onPressed: loading ? null : togglePlay,
                      icon: loading
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill),
                      iconSize: 36,
                      color: colors.primary,
                    ),
            ),
          ),
          Text(
            controller == null
                ? ''
                : '${formatMediaTime(position)} / ${formatMediaTime(duration)}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progress, minHeight: 3),
        ],
      ),
    );
  }
}

/// Full-size video player with play/pause, a seek bar and Download.
class VideoPlayerDialog extends StatefulWidget {
  const VideoPlayerDialog(
      {super.key, required this.file, required this.loadLink, this.onDownload});
  final Map<String, dynamic> file;
  final MediaLinkLoader loadLink;
  final Future<void> Function()? onDownload;

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog>
    with _MediaController {
  @override
  Map<String, dynamic> get file => widget.file;
  @override
  MediaLinkLoader get loadLink => widget.loadLink;

  @override
  void initState() {
    super.initState();
    unawaited(togglePlay());
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    final value = player?.value;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    return Dialog(
      key: const ValueKey('attachment-video-player'),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const SizedBox(width: 16),
            Expanded(
                child: Text(widget.file['name']?.toString() ?? 'Video',
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (widget.onDownload != null)
              IconButton(
                  tooltip: 'Download file',
                  onPressed: widget.onDownload,
                  icon: const Icon(Icons.download)),
            IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close)),
          ]),
          if (failure != null)
            Padding(
                padding: const EdgeInsets.all(24),
                child: Text(failure!, key: const ValueKey('media-failure')))
          else if (player == null)
            const Padding(
                padding: EdgeInsets.all(48), child: CircularProgressIndicator())
          else ...[
            Flexible(
              child: GestureDetector(
                onTap: togglePlay,
                child: AspectRatio(
                    aspectRatio: value!.aspectRatio,
                    child: VideoPlayer(player)),
              ),
            ),
            Row(children: [
              IconButton(
                  key: const ValueKey('video-play'),
                  tooltip: value.isPlaying ? 'Pause' : 'Play',
                  onPressed: togglePlay,
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow)),
              Expanded(
                child: Slider(
                  value: duration > Duration.zero
                      ? position.inMilliseconds
                          .clamp(0, duration.inMilliseconds)
                          .toDouble()
                      : 0,
                  max: duration > Duration.zero
                      ? duration.inMilliseconds.toDouble()
                      : 1,
                  onChanged: duration > Duration.zero
                      ? (ms) =>
                          player.seekTo(Duration(milliseconds: ms.round()))
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                    '${formatMediaTime(position)} / ${formatMediaTime(duration)}'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
