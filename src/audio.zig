const std = @import("std");
const a = @import("app.zig");
const rl = a.rl;

pub fn pump(app: *a.App) void {
    const target = a.FRAME_FRAMES * 2;
    const is_playing = app.system != null and !app.paused and app.view == .playing and !app.muted;
    if (is_playing and !app.audio_was_playing and app.audio_silence_samples == 0) {
        app.audio_silence_samples = a.SAMPLE_RATE / 20;
    }
    app.audio_was_playing = is_playing;
    const vol_norm: f32 = @as(f32, @floatFromInt(app.volume)) / 100.0;
    const target_gain: f32 = if (is_playing) vol_norm else 0.0;
    const smooth_rate: f32 = if (target_gain > app.audio_smooth_gain) 0.0003 else 0.002;

    var attempts: u32 = 0;
    while (rl.IsAudioStreamProcessed(app.audio_stream) and attempts < 8) : (attempts += 1) {
        var pos: usize = 0;
        if (app.system) |emu| {
            while (pos < target) {
                const n = emu.drainAudio(app.audio_scratch[pos..target]);
                if (n == 0) break;
                pos += n;
            }
        }
        if (pos < target) {
            const last_l: f32 = if (pos >= 2) app.audio_scratch[pos - 2] else 0;
            const last_r: f32 = if (pos >= 2) app.audio_scratch[pos - 1] else 0;
            const fade_len: f32 = @floatFromInt(target - pos);
            var i: usize = pos;
            var step: usize = 0;
            while (i + 1 < target) : (i += 2) {
                const t: f32 = 1.0 - @as(f32, @floatFromInt(step)) / fade_len;
                app.audio_scratch[i] = last_l * t;
                app.audio_scratch[i + 1] = last_r * t;
                step += 2;
            }
        }
        var k: usize = 0;
        while (k < target) : (k += 2) {
            if (app.audio_silence_samples > 0) {
                app.audio_smooth_gain = 0;
                app.audio_i16[k] = 0;
                app.audio_i16[k + 1] = 0;
                app.audio_silence_samples -= 1;
                continue;
            }
            app.audio_smooth_gain += (target_gain - app.audio_smooth_gain) * smooth_rate;
            var vl = app.audio_scratch[k];
            var vr = app.audio_scratch[k + 1];
            if (std.math.isNan(vl) or std.math.isInf(vl)) vl = 0;
            if (std.math.isNan(vr) or std.math.isInf(vr)) vr = 0;
            vl *= app.audio_smooth_gain;
            vr *= app.audio_smooth_gain;
            if (vl > 1.0) vl = 1.0;
            if (vl < -1.0) vl = -1.0;
            if (vr > 1.0) vr = 1.0;
            if (vr < -1.0) vr = -1.0;
            app.audio_i16[k] = @intFromFloat(vl * 32767.0);
            app.audio_i16[k + 1] = @intFromFloat(vr * 32767.0);
        }
        if (pos < target and is_playing) {
            app.audio_underrun_streak +%= 1;
            if (app.audio_underrun_streak == 240) {
                a.setFlashMsg(app, "Audio underrun", .{});
            }
        } else if (pos == target) {
            app.audio_underrun_streak = 0;
        }
        rl.UpdateAudioStream(app.audio_stream, &app.audio_i16, a.FRAME_FRAMES);
    }
}
