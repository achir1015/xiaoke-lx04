package com.achir.xiaoke;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.view.View;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;

/**
 * 小柯「病房助理工作站」首頁：上方日期/農曆/時鐘/音量列 + 左側頭盔機器人 + 右側農民曆卡片。
 * 版面以 512x300 邏輯座標排版（由 ESP32 XiaoKe_P4 移植），繪製時縮放填滿實際螢幕（LX04 為 800x480）。
 * 回答時改為精簡模式：左側小機器人 + 右側字幕。
 */
final class FaceView extends View {
    enum State { IDLE, LISTENING, THINKING, SPEAKING, SLEEPY, ERROR }

    private static final float LW = 512f, LH = 300f;
    private static final float BAR_H = 44f, LINE_H = 18f;

    // 配色（對應 XiaoKe_P4 的 C_*）
    private static final int C_BG = 0xFF000000;
    private static final int C_WHITE = 0xFFFFFFFF;
    private static final int C_GLOW = 0xFF40E8FF;
    private static final int C_GLOW_DIM = 0xFF1E6E87;
    private static final int C_RED2 = 0xFFFF4664;
    private static final int C_PANEL = 0xFF0E1626;
    private static final int C_BAR_LINE = 0xFF283448;
    private static final int C_ORANGE = 0xFFFFA600;
    private static final int C_YELLOW = 0xFFFFE000;
    private static final int C_GRAY = 0xFF8A94A2;
    private static final int C_GREEN = 0xFF2FD36A;
    private static final int C_PINK = 0xFFFF6F91;
    private static final int C_VISOR = 0xFF162A42;
    private static final int C_BLACK = 0xFF081018;

    // 表情
    private static final int EX_NORMAL = 0, EX_HAPPY = 1, EX_LOVE = 2, EX_SURPRISE = 3, EX_SAD = 4,
            EX_ANGRY = 5, EX_WINK = 6, EX_SHY = 7, EX_LISTEN = 8, EX_THINK = 9, EX_SLEEPY = 10;

    private volatile State state = State.IDLE;
    private volatile String emotion = "happy";
    private volatile String subtitle = "";
    private volatile String userText = "";
    private volatile String status = "";
    private volatile String ip = "";
    private volatile int volume = -1;
    private volatile float level = 0f;

    // 病房助理工作站
    private Portal portal;
    private volatile boolean portalMode = false;
    private int portalCat = -1, portalPage = 0;
    private Portal.Tool portalSel = null;
    private long portalSince = 0;

    private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pClock = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pBmp = new Paint();
    private final long start = System.currentTimeMillis();

    FaceView(Context c) {
        super(c);
        pClock.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
        pClock.setTextSize(34);
        setKeepScreenOn(true);
    }

    void setState(State s) { state = s; postInvalidate(); }
    State getState() { return state; }
    void setEmotion(String e) { emotion = e == null ? "happy" : e; postInvalidate(); }
    void setSubtitle(String s) { subtitle = s == null ? "" : s; postInvalidate(); }
    void setUserText(String s) { userText = s == null ? "" : s; postInvalidate(); }
    void setStatus(String s) { status = s == null ? "" : s; postInvalidate(); }
    void setIp(String s) { ip = s == null ? "" : s; }
    void setVolume(int v) { volume = v; }
    void setLevel(float l) { level = l; if (state == State.LISTENING) postInvalidate(); }
    interface ToolListener { void onOpen(String url, String name); }
    private ToolListener toolListener;
    void setPortal(Portal pt) { portal = pt; }
    void setToolListener(ToolListener l) { toolListener = l; }
    private Runnable deckListener;
    void setDeckListener(Runnable r) { deckListener = r; }
    boolean isPortalOpen() { return portalMode; }
    void closePortal() { portalMode = false; postInvalidate(); }

    /** 處理觸控（傳入實際像素座標）。回傳 true = 已被工作站選單吃掉，不要去啟動語音。 */
    boolean handleTouch(float sx, float sy) {
        float x = sx * LW / Math.max(1, getWidth()), y = sy * LH / Math.max(1, getHeight());
        if (!portalMode) {
            if (portal != null && !portal.isEmpty() && hit(x, y, 370, 274, 136, 24)) {  // 右下角標籤
                portalMode = true; portalCat = -1; portalPage = 0; portalSel = null;
                portalSince = System.currentTimeMillis();
                postInvalidate();
                return true;
            }
            if (deckListener != null && hit(x, y, 238, 274, 108, 24)) {   // Stream Deck 標籤
                deckListener.run();
                return true;
            }
            return false;
        }
        portalSince = System.currentTimeMillis();
        if (hit(x, y, 410, 50, 96, 24)) { portalMode = false; postInvalidate(); return true; }  // 回主畫面
        if (portalSel != null) {
            if (hit(x, y, 8, 268, 120, 26)) portalSel = null;                                   // 返回清單
            postInvalidate();
            return true;
        }
        int n = portal.cats.size() + 1;
        float w = (LW - 16) / n;
        for (int i = 0; i < n; i++)
            if (hit(x, y, 8 + i * w, 80, w - 4, 24)) { portalCat = i - 1; portalPage = 0; }
        List<Portal.Tool> v = portal.filtered(portalCat);
        int pages = Math.max(1, (v.size() + 7) / 8);
        if (pages > 1 && hit(x, y, 250, 50, 72, 24) && portalPage > 0) portalPage--;
        if (pages > 1 && hit(x, y, 328, 50, 72, 24) && portalPage < pages - 1) portalPage++;
        int pg = Math.min(Math.max(portalPage, 0), pages - 1);
        for (int k = 0; k < 8 && pg * 8 + k < v.size(); k++)
            if (hit(x, y, 8 + (k % 2) * 250, 110 + (k / 2) * 46, 244, 42)) {
                Portal.Tool t = v.get(pg * 8 + k);
                if (toolListener != null) toolListener.onOpen(t.url, t.full);   // 直接在螢幕上開啟網頁
                else portalSel = t;
            }
        postInvalidate();
        return true;
    }

    private static boolean hit(float x, float y, float bx, float by, float bw, float bh) {
        return x >= bx && x < bx + bw && y >= by && y < by + bh;
    }

    private int expression() {
        switch (state) {
            case SLEEPY: return EX_SLEEPY;
            case LISTENING: return EX_LISTEN;
            case THINKING: return EX_THINK;
            case ERROR: return EX_SAD;
            default:
                switch (emotion) {
                    case "love": return EX_LOVE;
                    case "surprise": return EX_SURPRISE;
                    case "sad": return EX_SAD;
                    case "angry": return EX_ANGRY;
                    case "wink": return EX_WINK;
                    case "shy": return EX_SHY;
                    case "happy": return EX_HAPPY;
                    default: return EX_NORMAL;
                }
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth(), h = getHeight();
        canvas.drawColor(C_BG);
        canvas.save();
        canvas.scale(w / LW, h / LH);

        long now = System.currentTimeMillis();
        float t = (now - start) / 1000f;
        int ex = expression();
        boolean blink = ex != EX_SLEEPY && ex != EX_LISTEN && (t % 4.2f) < 0.13f;
        float lx = ex == EX_THINK ? (float) Math.sin(t * 3) * 8 : 0;
        float ly = ex == EX_THINK ? (float) Math.cos(t * 2.1) * 4 : 0;
        float mouth = state == State.SPEAKING ? 0.3f + Math.abs((float) Math.sin(t * 13)) * 0.7f : 0f;

        if (portalMode && System.currentTimeMillis() - portalSince > Config.PORTAL_TIMEOUT_SEC * 1000L)
            portalMode = false;

        boolean compact = (state == State.THINKING || state == State.SPEAKING || state == State.ERROR)
                && (!subtitle.isEmpty() || !userText.isEmpty());

        if (portalMode && portal != null) {
            drawPortal(canvas, now);
            drawTopBar(canvas, now);
        } else if (!compact) {
            drawRobot(canvas, 150, 168, 0.86f, ex, lx, ly, blink, mouth, now);
            drawAlmanac(canvas, 300, 52, 206, 220);
            drawTopBar(canvas, now);
            String hint = state == State.LISTENING ? "聆聽中…"
                    : state == State.SLEEPY ? "想睡…（說話或點我叫醒）"
                    : !status.isEmpty() ? status
                    : Config.VOICE_ACTIVATION ? "待命中，直接跟我說話" : "按住螢幕說話";
            p.setTypeface(Typeface.DEFAULT);
            p.setTextSize(16);
            p.setColor(state == State.LISTENING ? C_GREEN : C_GRAY);
            canvas.drawText(hint, 8, 280, p);
            if (!ip.isEmpty()) {
                p.setColor(C_GLOW_DIM);
                canvas.drawText(ip, 8, 297, p);
            }
            if (state == State.LISTENING) drawMicBars(canvas, 206, 293);
            else drawPageDots(canvas, 208, 291);
            drawWorkstationLabel(canvas);
            if (deckListener != null) drawDeckLabel(canvas);
        } else {
            drawRobot(canvas, 96, 168, 0.6f, ex, lx * 0.6f, ly * 0.6f, blink, mouth, now);
            drawTopBar(canvas, now);
            float tx = 196, tw = LW - tx - 10;
            float y = 66;
            p.setTypeface(Typeface.DEFAULT);
            if (!userText.isEmpty()) {
                p.setTextSize(15);
                p.setColor(C_GRAY);
                List<String> us = wrap("你：" + userText, tw, p);
                for (int i = 0; i < Math.min(2, us.size()); i++, y += LINE_H - 2)
                    canvas.drawText(us.get(i), tx, y, p);
                y += 6;
            }
            String body = state == State.THINKING && subtitle.isEmpty() ? "思考中…" : subtitle;
            p.setTextSize(17);
            p.setColor(state == State.ERROR ? C_RED2 : state == State.SPEAKING ? C_ORANGE : C_GLOW);
            List<String> lines = wrap(body, tw, p);
            p.setColor(C_WHITE);
            int per = (int) ((LH - y) / LINE_H);
            int pages = Math.max(1, (lines.size() + per - 1) / per);
            int page = (int) ((now - start) / 4500) % pages;
            for (int i = 0; i < per && page * per + i < lines.size(); i++)
                canvas.drawText(lines.get(page * per + i), tx, y + i * LINE_H, p);
        }

        canvas.restore();
        postInvalidateDelayed(state == State.IDLE || state == State.SLEEPY ? 60 : 33);
    }

    // ---------------- 上方列 ----------------
    private void drawTopBar(Canvas cv, long now) {
        Calendar c = Calendar.getInstance();
        final String[] WD = {"週日", "週一", "週二", "週三", "週四", "週五", "週六"};
        String date = String.format("%d/%02d/%02d %s", c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1,
                c.get(Calendar.DAY_OF_MONTH), WD[c.get(Calendar.DAY_OF_WEEK) - 1]);
        String lunar = Almanac.lunarString(c);
        if (!lunar.isEmpty() && !lunar.startsWith("閏")) lunar = "農曆" + lunar;
        String time = String.format("%02d:%02d:%02d", c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE), c.get(Calendar.SECOND));

        p.setColor(C_BG);
        cv.drawRect(0, 0, LW, BAR_H, p);
        p.setColor(C_BAR_LINE);
        cv.drawRect(0, BAR_H - 1, LW, BAR_H, p);

        p.setTypeface(Typeface.DEFAULT);
        p.setTextSize(16);
        p.setColor(C_GLOW);
        cv.drawText(date, 6, 19, p);
        p.setColor(C_ORANGE);
        cv.drawText(lunar, 6, 39, p);

        pClock.setColor(C_WHITE);
        float cw = pClock.measureText(time);
        cv.drawText(time, (LW - cw) / 2 + 8, 36, pClock);

        p.setColor(C_YELLOW);
        p.setTextSize(15);
        cv.drawText("音量", 470, 19, p);
        if (volume >= 0) cv.drawText(volume + "%", 470, 39, p);
        p.setColor(C_GLOW);
        cv.drawCircle(458, 13, 4, p);
    }

    // ---------------- 農民曆卡片 ----------------
    private void drawAlmanac(Canvas cv, float x0, float y0, float w, float h) {
        Almanac a = Almanac.compute(Calendar.getInstance());
        p.setColor(C_PANEL);
        cv.drawRoundRect(new RectF(x0, y0, x0 + w, y0 + h), 8, 8, p);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(1);
        p.setColor(C_BAR_LINE);
        cv.drawRoundRect(new RectF(x0, y0, x0 + w, y0 + h), 8, 8, p);
        p.setStyle(Paint.Style.FILL);

        float x = x0 + 10, y = y0 + 22, tw = w - 20;
        p.setTypeface(Typeface.DEFAULT);
        p.setTextSize(16);
        p.setColor(C_YELLOW);
        cv.drawText("農民曆", x, y, p);
        if (!a.ok) {
            p.setColor(C_GRAY);
            cv.drawText("等待校時…", x, y + 26, p);
            return;
        }
        String yz = a.yearGZ + "年【" + a.zodiac + "】";
        p.setColor(C_ORANGE);
        cv.drawText(yz, x0 + w - 10 - p.measureText(yz), y, p);
        p.setColor(C_BAR_LINE);
        cv.drawRect(x, y + 6, x + tw, y + 7, p);

        y += 26;
        p.setColor(C_WHITE);
        cv.drawText(a.monthGZ + "月　" + a.dayGZ + "日　" + a.jianchu + "日", x, y, p);
        y += LINE_H + 2;
        p.setColor(C_GLOW);
        cv.drawText(a.chong + "　煞" + a.sha, x, y, p);
        y += LINE_H + 6;
        y = drawYiJi(cv, "宜", C_GREEN, a.yi, x, y, tw);
        y = drawYiJi(cv, "忌", C_RED2, a.ji, x, y, tw);
        p.setColor(C_ORANGE);
        if (!a.termToday.isEmpty()) cv.drawText("今日節氣：" + a.termToday, x, y + 2, p);
        else cv.drawText("下個節氣：" + a.nextTerm, x, y + 2, p);
    }

    private float drawYiJi(Canvas cv, String label, int lc, String txt, float x, float y, float tw) {
        p.setColor(lc);
        cv.drawRoundRect(new RectF(x, y - 14, x + 20, y + 4), 4, 4, p);
        p.setColor(C_BLACK);
        p.setTextSize(15);
        cv.drawText(label, x + 2, y, p);
        p.setTextSize(16);
        p.setColor(C_WHITE);
        List<String> ls = wrap(txt, tw - 26, p);
        int n = Math.min(ls.size(), 3);
        for (int i = 0; i < n; i++) cv.drawText(ls.get(i), x + 26, y + i * LINE_H, p);
        return y + Math.max(1, n) * LINE_H + 6;
    }

    // ---------------- 機器人（頭盔 + 面罩 + 眼睛 + 嘴巴 + Zzz）----------------
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint glow = new Paint(Paint.ANTI_ALIAS_FLAG);

    private void drawRobot(Canvas cv, float vx, float vy, float s, int ex, float lx, float ly,
                           boolean blink, float mouthOpen, long now) {
        final float X = vx, Y = vy;
        int g = ex == EX_ANGRY ? C_RED2 : C_GLOW;

        // 耳罩
        for (int side = -1; side <= 1; side += 2) {
            float cx = X + side * S(121, s);
            rrGrad(cv, cx - S(19, s), Y - S(44, s), S(38, s), S(92, s), S(16, s), 0xFFB0BED2, 0xFF687892);
            rr(cv, cx - S(5, s) + side * S(6, s), Y - S(30, s), S(9, s), S(56, s), S(5, s), 0xFFCED8E8);
        }
        // 頭盔
        rr(cv, X - S(125, s), Y - S(96, s), S(250, s), S(198, s), S(90, s), 0xFF808A9A);
        rrGrad(cv, X - S(124, s), Y - S(99, s), S(248, s), S(194, s), S(88, s), 0xFFFCFDFF, 0xFFC4CBD6);
        ellipse(cv, X - S(62, s), Y - S(80, s), S(34, s), S(9, s), C_WHITE);
        // 面罩
        rr(cv, X - S(102, s), Y - S(71, s), S(204, s), S(142, s), S(56, s), 0xFF344660);
        rrGrad(cv, X - S(98, s), Y - S(67, s), S(196, s), S(134, s), S(52, s), 0xFF1E3450, 0xFF091220);
        ellipse(cv, X - S(50, s), Y - S(52, s), S(32, s), S(7, s), 0xFF2C4666);

        float ey = Y - S(10, s), dx = S(44, s), my = Y + S(34, s);
        float th = Math.max(2f, S(5, s));
        boolean talking = mouthOpen > 0.05f;
        boolean smiley = ex == EX_NORMAL || ex == EX_HAPPY || ex == EX_WINK || ex == EX_LOVE || ex == EX_SHY;

        if (ex == EX_SHY || ex == EX_LOVE)
            for (int side = -1; side <= 1; side += 2)
                ellipse(cv, X + side * S(68, s), Y + S(20, s), S(15, s), S(6, s), blend(C_VISOR, C_PINK, 0.55f));

        // 嘴巴
        if (talking) {
            float rx = S(15, s), ry = Math.max(S(4, s), S(4 + 13 * mouthOpen, s));
            ellipse(cv, X, my - S(4, s), rx, ry, g);
            if (ry > S(7, s)) ellipse(cv, X, my - S(4, s), rx - S(5, s), ry - S(5, s), 0xFF0E3C52);
        } else if (smiley) {
            arc(cv, X, my - S(18, s), S(18, s), 35, 110, th, g);
        } else if (ex == EX_SURPRISE || ex == EX_LISTEN) {
            float r = S(ex == EX_SURPRISE ? 9 : 7, s) + (ex == EX_LISTEN ? Math.min(S(6, s), level * S(10, s)) : 0);
            ellipse(cv, X, my - S(2, s), r, r, g);
            if (ex == EX_LISTEN) ellipse(cv, X, my - S(2, s), Math.max(1, r - th), Math.max(1, r - th), C_VISOR);
        } else if (ex == EX_SAD || ex == EX_ANGRY) {
            arc(cv, X, my + S(12, s), S(16, s), 215, 110, th, g);
        } else if (ex == EX_THINK) {
            for (int i = 0; i < 3; i++) {
                fill.setColor((now / 250) % 3 == i ? g : C_GLOW_DIM);
                cv.drawCircle(X + (i - 1) * S(14, s), my - S(2, s), S(4, s), fill);
            }
        } else if (ex == EX_SLEEPY) {
            arc(cv, X, my + S(4, s), S(8, s), 200, 140, th, g);
        } else {
            line(cv, X - S(13, s), my - S(2, s), X + S(13, s), my - S(2, s), th, g);
        }

        // 眼睛
        float ew = S(22, s), eh = S(32, s);
        for (int side = -1; side <= 1; side += 2) {
            float cx = X + side * dx, x = cx + lx, y = ey + ly;
            switch (ex) {
                case EX_HAPPY: case EX_SHY:
                    arc(cv, cx, ey + S(8, s), S(12, s), 200, 140, th + 1, g); break;
                case EX_WINK:
                    if (side < 0) line(cv, cx - S(11, s), ey, cx + S(11, s), ey, th + 1, g);
                    else eye(cv, x, y, ew, eh, g, th);
                    break;
                case EX_LOVE: {
                    float r = S(15, s) + S(2, s) * (float) Math.sin(now / 150.0);
                    heart(cv, cx, ey - S(2, s), r, C_PINK);
                    break;
                }
                case EX_SURPRISE:
                    ellipse(cv, cx, ey, S(10, s), S(10, s), g); break;
                case EX_SLEEPY:
                    arc(cv, cx, ey - S(6, s), S(11, s), 20, 140, th, g); break;
                case EX_THINK:
                    eye(cv, cx + S(6, s), ey - S(8, s), ew, S(20, s), g, th); break;
                default: {
                    float w = ex == EX_LISTEN ? S(25, s) : ew;
                    float hh = ex == EX_LISTEN ? S(36, s) : ex == EX_ANGRY ? S(24, s) : ex == EX_SAD ? S(26, s) : eh;
                    if (blink && ex != EX_LISTEN) line(cv, x - w / 2, y, x + w / 2, y, th + 1, g);
                    else eye(cv, x, y, w, hh, g, th);
                    if (ex == EX_SAD)
                        line(cv, x - S(13, s), y - hh / 2 - S(7, s) + S(5, s) * side, x + S(13, s), y - hh / 2 - S(7, s) - S(5, s) * side, th, g);
                    if (ex == EX_ANGRY)
                        line(cv, x - S(13, s), y - hh / 2 - S(9, s) - S(6, s) * side, x + S(13, s), y - hh / 2 - S(9, s) + S(6, s) * side, th, g);
                }
            }
        }

        // 想睡 Zzz
        if (ex == EX_SLEEPY) {
            int kz = (int) ((now / 500) % 3);
            p.setColor(C_GLOW);
            p.setTypeface(Typeface.DEFAULT_BOLD);
            p.setTextSize(14 * s + 8);
            cv.drawText("z", vx + 100 * s, vy - 78 * s - kz * 3, p);
            p.setTextSize(20 * s + 10);
            cv.drawText("Z", vx + 114 * s, vy - 96 * s - kz * 3, p);
        }
    }

    // 眼睛（圓角矩形 + 內發光）
    private void eye(Canvas cv, float cx, float cy, float w, float h, int color, float glowTh) {
        glow.setColor(color);
        glow.setStyle(Paint.Style.FILL);
        glow.setMaskFilter(new android.graphics.BlurMaskFilter(6, android.graphics.BlurMaskFilter.Blur.NORMAL));
        cv.drawRoundRect(new RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), w / 2, w / 2, glow);
        glow.setMaskFilter(null);
        fill.setColor(color);
        cv.drawRoundRect(new RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), w / 2, w / 2, fill);
    }

    // ---------------- 低階繪圖 ----------------
    private static float S(float v, float s) { return v * s; }

    private void rr(Canvas cv, float x, float y, float w, float h, float r, int color) {
        fill.setColor(color);
        fill.setShader(null);
        cv.drawRoundRect(new RectF(x, y, x + w, y + h), r, r, fill);
    }

    private void rrGrad(Canvas cv, float x, float y, float w, float h, float r, int c1, int c2) {
        fill.setShader(new LinearGradient(x, y, x, y + h, c1, c2, Shader.TileMode.CLAMP));
        cv.drawRoundRect(new RectF(x, y, x + w, y + h), r, r, fill);
        fill.setShader(null);
    }

    private void ellipse(Canvas cv, float cx, float cy, float rx, float ry, int color) {
        fill.setColor(color);
        fill.setShader(null);
        cv.drawOval(new RectF(cx - rx, cy - ry, cx + rx, cy + ry), fill);
    }

    private void arc(Canvas cv, float cx, float cy, float r, float startDeg, float sweepDeg, float th, int color) {
        glow.setStyle(Paint.Style.STROKE);
        glow.setStrokeCap(Paint.Cap.ROUND);
        glow.setStrokeWidth(th);
        glow.setColor(color);
        glow.setMaskFilter(new android.graphics.BlurMaskFilter(5, android.graphics.BlurMaskFilter.Blur.NORMAL));
        RectF o = new RectF(cx - r, cy - r, cx + r, cy + r);
        cv.drawArc(o, startDeg, sweepDeg, false, glow);
        glow.setMaskFilter(null);
        cv.drawArc(o, startDeg, sweepDeg, false, glow);
    }

    private void line(Canvas cv, float x0, float y0, float x1, float y1, float th, int color) {
        glow.setStyle(Paint.Style.STROKE);
        glow.setStrokeCap(Paint.Cap.ROUND);
        glow.setStrokeWidth(th);
        glow.setColor(color);
        glow.setMaskFilter(new android.graphics.BlurMaskFilter(5, android.graphics.BlurMaskFilter.Blur.NORMAL));
        cv.drawLine(x0, y0, x1, y1, glow);
        glow.setMaskFilter(null);
        cv.drawLine(x0, y0, x1, y1, glow);
    }

    private void heart(Canvas cv, float cx, float cy, float r, int color) {
        Path path = new Path();
        path.moveTo(cx, cy + r * 0.9f);
        path.cubicTo(cx - r * 1.3f, cy - r * 0.1f, cx - r * 0.7f, cy - r, cx, cy - r * 0.3f);
        path.cubicTo(cx + r * 0.7f, cy - r, cx + r * 1.3f, cy - r * 0.1f, cx, cy + r * 0.9f);
        glow.setStyle(Paint.Style.FILL);
        glow.setColor(color);
        glow.setMaskFilter(new android.graphics.BlurMaskFilter(5, android.graphics.BlurMaskFilter.Blur.NORMAL));
        cv.drawPath(path, glow);
        glow.setMaskFilter(null);
        cv.drawPath(path, glow);
    }

    private void drawMicBars(Canvas cv, float x, float y) {
        fill.setShader(null);
        for (int i = 0; i < 4; i++) {
            float lv = Math.min(1f, level * 1.4f);
            boolean on = lv * 4 > i;
            fill.setColor(on ? C_GREEN : C_GLOW_DIM);
            float bh = 4 + i * 3;
            cv.drawRect(x + i * 6, y - bh, x + i * 6 + 4, y, fill);
        }
    }

    private void drawPageDots(Canvas cv, float x, float y) {
        fill.setShader(null);
        fill.setColor(C_GLOW_DIM);
        for (int i = 0; i < 4; i++) cv.drawCircle(x + i * 7, y, 1.6f, fill);
    }

    private void drawWorkstationLabel(Canvas cv) {
        float w = 150, h = 24, x = LW - w - 8, y = LH - h - 4;
        fill.setShader(null);
        fill.setColor(C_GLOW_DIM);
        cv.drawRoundRect(new RectF(x, y, x + w, y + h), 10, 10, fill);
        p.setTypeface(Typeface.DEFAULT_BOLD);
        p.setTextSize(16);
        p.setColor(C_WHITE);
        String s = "病房助理工作站";
        cv.drawText(s, x + (w - p.measureText(s)) / 2, y + 17, p);
    }

    private void drawDeckLabel(Canvas cv) {
        float w = 100, h = 24, x = 246, y = LH - h - 4;
        fill.setShader(null);
        fill.setColor(C_ORANGE);
        cv.drawRoundRect(new RectF(x, y, x + w, y + h), 10, 10, fill);
        p.setTypeface(Typeface.DEFAULT_BOLD);
        p.setTextSize(15);
        p.setColor(C_BG);
        String s = "Stream Deck";
        cv.drawText(s, x + (w - p.measureText(s)) / 2, y + 17, p);
    }

    // ---------------- 病房助理工作站選單 ----------------
    private void drawPortal(Canvas cv, long now) {
        p.setTypeface(Typeface.DEFAULT);
        p.setTextSize(16);
        p.setColor(C_ORANGE);
        cv.drawText(Config.PORTAL_NAME, 8, 68, p);
        drawBtn(cv, 410, 50, 96, 24, "回主畫面", C_BAR_LINE, C_WHITE);

        if (portal.isEmpty()) {
            p.setColor(C_GRAY);
            cv.drawText("工具清單讀取失敗", 8, 120, p);
            return;
        }

        if (portalSel != null) {                                   // ---- 詳細頁 ----
            p.setTextSize(16);
            p.setColor(C_GLOW);
            cv.drawText(clip(portalSel.full, 276, p), 8, 104, p);
            p.setColor(C_GRAY);
            cv.drawText("類別：" + portalSel.cat, 8, 126, p);
            p.setColor(C_WHITE);
            List<String> ls = wrap("用手機掃描右邊的 QR 碼開啟；或在同一個 Wi-Fi 下，用手機瀏覽器開啟首頁左下角的網址來點選。", 276, p);
            for (int i = 0; i < Math.min(4, ls.size()); i++) cv.drawText(ls.get(i), 8, 150 + i * LINE_H, p);
            p.setColor(C_GLOW_DIM);
            p.setTextSize(13);
            List<String> us = wrap(portalSel.url, 276, p);
            for (int i = 0; i < Math.min(2, us.size()); i++) cv.drawText(us.get(i), 8, 232 + i * 16, p);

            float qx = 296, qy = 84, qw = 200;
            fill.setShader(null);
            fill.setColor(C_WHITE);
            cv.drawRoundRect(new RectF(qx, qy, qx + qw, qy + qw), 6, 6, fill);
            android.graphics.Bitmap bmp = portal.qr(portalSel.id);
            if (bmp != null) cv.drawBitmap(bmp, null, new RectF(qx + 10, qy + 10, qx + qw - 10, qy + qw - 10), pBmp);
            p.setColor(C_GRAY);
            p.setTextSize(14);
            String cap = "手機掃描開啟";
            cv.drawText(cap, qx + (qw - p.measureText(cap)) / 2, qy + qw + 14, p);
            drawBtn(cv, 8, 268, 120, 26, "返回清單", C_BAR_LINE, C_WHITE);
            return;
        }

        // ---- 清單頁 ----
        int n = portal.cats.size() + 1;
        float w = (LW - 16) / n;
        for (int i = 0; i < n; i++) {
            boolean on = (i == 0 && portalCat < 0) || (i > 0 && portalCat == i - 1);
            drawBtn(cv, 8 + i * w, 80, w - 4, 24, i == 0 ? "全部" : portal.cats.get(i - 1),
                    on ? C_GLOW_DIM : C_PANEL, on ? C_WHITE : C_GRAY);
        }
        List<Portal.Tool> v = portal.filtered(portalCat);
        int pages = Math.max(1, (v.size() + 7) / 8);
        int pg = Math.min(Math.max(portalPage, 0), pages - 1);
        if (pages > 1) {
            drawBtn(cv, 250, 50, 72, 24, "上一頁", pg > 0 ? C_BAR_LINE : C_PANEL, pg > 0 ? C_WHITE : C_GRAY);
            drawBtn(cv, 328, 50, 72, 24, "下一頁", pg < pages - 1 ? C_BAR_LINE : C_PANEL, pg < pages - 1 ? C_WHITE : C_GRAY);
            p.setColor(C_GRAY);
            p.setTextSize(15);
            cv.drawText((pg + 1) + "/" + pages, 200, 68, p);
        }
        for (int k = 0; k < 8 && pg * 8 + k < v.size(); k++) {
            Portal.Tool t = v.get(pg * 8 + k);
            float bx = 8 + (k % 2) * 250, by = 110 + (k / 2) * 46;
            fill.setShader(null);
            fill.setColor(C_PANEL);
            cv.drawRoundRect(new RectF(bx, by, bx + 244, by + 42), 6, 6, fill);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(1);
            p.setColor(C_BAR_LINE);
            cv.drawRoundRect(new RectF(bx, by, bx + 244, by + 42), 6, 6, p);
            p.setStyle(Paint.Style.FILL);
            p.setColor(C_WHITE);
            p.setTextSize(16);
            cv.drawText(clip(t.name, 228, p), bx + 8, by + 18, p);
            p.setColor(C_GRAY);
            p.setTextSize(13);
            cv.drawText(clip(t.url, 228, p), bx + 8, by + 36, p);
        }
        if (v.isEmpty()) {
            p.setColor(C_GLOW_DIM);
            cv.drawText("這個類別沒有工具", 8, 140, p);
        }
    }

    private void drawBtn(Canvas cv, float x, float y, float w, float h, String label, int bg, int fg) {
        fill.setShader(null);
        fill.setColor(bg);
        cv.drawRoundRect(new RectF(x, y, x + w, y + h), 6, 6, fill);
        p.setTypeface(Typeface.DEFAULT);
        p.setTextSize(15);
        p.setColor(fg);
        cv.drawText(label, x + (w - p.measureText(label)) / 2, y + h / 2 + 6, p);
    }

    private String clip(String s, float maxW, Paint paint) {
        if (paint.measureText(s) <= maxW) return s;
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            if (paint.measureText(b.toString() + s.charAt(i) + "…") > maxW) break;
            b.append(s.charAt(i));
        }
        return b + "…";
    }

    // 以邏輯寬度斷行（中英混排，逐字量測）
    private List<String> wrap(String text, float maxW, Paint paint) {
        List<String> out = new ArrayList<>();
        if (text == null) return out;
        StringBuilder cur = new StringBuilder();
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == '\n') { out.add(cur.toString()); cur.setLength(0); continue; }
            cur.append(ch);
            if (paint.measureText(cur.toString()) > maxW) {
                cur.setLength(cur.length() - 1);
                out.add(cur.toString());
                cur.setLength(0);
                cur.append(ch);
            }
        }
        if (cur.length() > 0) out.add(cur.toString());
        return out;
    }

    private static int blend(int a, int b, float t) {
        int ar = (a >> 16) & 0xff, ag = (a >> 8) & 0xff, ab = a & 0xff;
        int br = (b >> 16) & 0xff, bg = (b >> 8) & 0xff, bb = b & 0xff;
        int r = (int) (ar + (br - ar) * t), gg = (int) (ag + (bg - ag) * t), bl = (int) (ab + (bb - ab) * t);
        return Color.argb(255, r, gg, bl);
    }
}
