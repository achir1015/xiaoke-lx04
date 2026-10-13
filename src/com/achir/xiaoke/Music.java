package com.achir.xiaoke;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.MediaPlayer;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.CountDownLatch;

/**
 * 自創歌曲：清單來自 assets/songs.json（Google 雲端公開分享的 mp3 / MV mp4），MediaPlayer 串流播放。
 * 與 iPhone 版 Music.swift 相同的點歌規則。
 */
final class Music {
    static final class Song {
        final String name, mp3, mp4;
        Song(String name, String mp3, String mp4) { this.name = name; this.mp3 = mp3; this.mp4 = mp4; }
    }

    static final int NONE = 0, LIST = 1, PLAY = 2, MV = 3;

    /** parse() 的結果：kind 與指定的歌（null = 隨機）。 */
    static final class Request {
        final int kind; final Song song;
        Request(int kind, Song song) { this.kind = kind; this.song = song; }
    }

    final List<Song> songs = new ArrayList<>();
    private final Random rnd = new Random();
    private int lastIndex = -1;
    private volatile MediaPlayer player;
    private volatile CountDownLatch done;
    private volatile boolean ok;

    void load(Context ctx) {
        songs.clear();
        try (InputStream in = ctx.getAssets().open("songs.json")) {
            byte[] buf = new byte[in.available()];
            int n = in.read(buf);
            JSONArray arr = new JSONArray(new String(buf, 0, Math.max(n, 0), "UTF-8"));
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                songs.add(new Song(o.optString("name"), o.optString("mp3"), o.optString("mp4", "")));
            }
        } catch (Exception ignored) {}
    }

    /** 點名歌名 → 那首；「看 MV」→ MV；「唱歌／放歌」→ 隨機；「有哪些歌」→ 列歌單。 */
    Request parse(String text) {
        if (songs.isEmpty() || text == null) return new Request(NONE, null);
        String t = text.replace(" ", "");
        boolean wantsMV = containsAny(t, "MV", "mv", "Mv", "ＭＶ", "影片", "音樂錄影帶");
        Song s = match(t);
        if (s != null) return new Request(wantsMV ? MV : PLAY, s);
        if (wantsMV) return new Request(MV, null);
        if (containsAny(t, "哪些歌", "什麼歌", "歌單", "幾首歌", "會唱什麼")) return new Request(LIST, null);
        if (containsAny(t, "唱歌", "唱首", "唱一首", "唱個", "首歌", "放歌", "放音樂", "播歌", "播放歌", "聽歌", "來首", "再一首", "下一首", "換一首"))
            return new Request(PLAY, null);
        return new Request(NONE, null);
    }

    private static boolean containsAny(String t, String... keys) {
        for (String k : keys) if (t.contains(k)) return true;
        return false;
    }

    private static String clean(String s) { return s.replaceAll("[，。、：:,. 　]", ""); }

    /**
     * 歌名比對（容忍語音辨識錯字，例如「花間謠」聽成「花間搖」）：
     * 句子與歌名的「最長連續相同字數」≥ 2，且佔歌名 ≥ 60%（或連續 ≥ 4 字）才算點到；多首都像時取比例最高的。
     */
    private Song match(String t) {
        String ct = clean(t);
        Song best = null;
        double bestScore = 0;
        for (Song s : songs) {
            String n = clean(s.name);
            if (n.isEmpty()) continue;
            if (ct.contains(n)) return s;
            int l = longestCommon(ct, n);
            double score = (double) l / n.length();
            if (l >= 2 && (score >= 0.6 || l >= 4) && score > bestScore) { best = s; bestScore = score; }
        }
        return best;
    }

    private static int longestCommon(String a, String b) {
        int best = 0;
        int[] prev = new int[b.length() + 1];
        for (int i = 1; i <= a.length(); i++) {
            int[] cur = new int[b.length() + 1];
            for (int j = 1; j <= b.length(); j++)
                if (a.charAt(i - 1) == b.charAt(j - 1)) { cur[j] = prev[j - 1] + 1; best = Math.max(best, cur[j]); }
            prev = cur;
        }
        return best;
    }

    Song random(boolean withMV) {
        if (withMV) {
            List<Song> pool = new ArrayList<>();
            for (Song s : songs) if (!s.mp4.isEmpty()) pool.add(s);
            if (!pool.isEmpty()) return pool.get(rnd.nextInt(pool.size()));
        }
        int i = rnd.nextInt(songs.size());
        if (songs.size() > 1 && i == lastIndex) i = (i + 1) % songs.size();
        lastIndex = i;
        return songs.get(i);
    }

    /** Google 雲端直接下載網址（confirm=t 跳過大檔案的病毒掃描提示頁）。 */
    static String url(String id) {
        return "https://drive.usercontent.google.com/download?id=" + id + "&export=download&confirm=t";
    }

    /** 播到結束回傳 true；被 stop() 或失敗回傳 false。會阻塞呼叫的執行緒（在 worker 執行緒呼叫）。 */
    boolean play(Song s) {
        stop();
        CountDownLatch latch = new CountDownLatch(1);
        done = latch;
        ok = false;
        try {
            MediaPlayer mp = new MediaPlayer();
            mp.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build());
            mp.setDataSource(url(s.mp3));
            mp.setOnPreparedListener(MediaPlayer::start);
            mp.setOnCompletionListener(p -> { ok = true; latch.countDown(); });
            mp.setOnErrorListener((p, what, extra) -> { latch.countDown(); return true; });
            player = mp;
            mp.prepareAsync();
            latch.await();
        } catch (Exception e) {
            latch.countDown();
        } finally {
            release();
        }
        return ok;
    }

    void stop() {
        CountDownLatch l = done;
        if (l != null) l.countDown();
        release();
    }

    boolean isPlaying() { return player != null; }

    private synchronized void release() {
        MediaPlayer mp = player;
        player = null;
        if (mp != null) {
            try { mp.stop(); } catch (Exception ignored) {}
            mp.release();
        }
    }
}
