package com.achir.xiaoke;

import android.content.Context;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 病房助理工作站的工具清單（來自 assets/tools.json）與 QR 圖（assets/qr/NN.png）。 */
final class Portal {
    static final class Tool {
        final int id;
        final String name, full, cat, url;
        Tool(int id, String name, String full, String cat, String url) {
            this.id = id; this.name = name; this.full = full; this.cat = cat; this.url = url;
        }
    }

    final List<Tool> tools = new ArrayList<>();
    final List<String> cats = new ArrayList<>();   // 類別名稱，依出現順序（不含「入口」id 0）
    private final Map<Integer, Bitmap> qrCache = new LinkedHashMap<>();
    private AssetManager assets;

    void load(Context ctx) {
        assets = ctx.getAssets();
        tools.clear();
        cats.clear();
        try (InputStream in = assets.open("tools.json")) {
            byte[] buf = new byte[in.available()];
            int n = in.read(buf);
            JSONArray arr = new JSONArray(new String(buf, 0, Math.max(n, 0), "UTF-8"));
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                Tool t = new Tool(o.getInt("id"), o.optString("name"), o.optString("full"),
                        o.optString("cat"), o.optString("url"));
                tools.add(t);
                if (t.id != 0 && !t.cat.isEmpty() && !cats.contains(t.cat)) cats.add(t.cat);
            }
        } catch (Exception ignored) {}
    }

    boolean isEmpty() { return tools.isEmpty(); }

    /** catIndex: -1 = 全部（不含 id 0 入口）；否則為 cats 的索引。 */
    List<Tool> filtered(int catIndex) {
        List<Tool> v = new ArrayList<>();
        for (Tool t : tools) {
            if (t.id == 0) continue;
            if (catIndex < 0 || catIndex >= cats.size() || t.cat.equals(cats.get(catIndex))) v.add(t);
        }
        return v;
    }

    Bitmap qr(int id) {
        Bitmap b = qrCache.get(id);
        if (b != null) return b;
        try (InputStream in = assets.open(String.format("qr/%02d.png", id))) {
            b = BitmapFactory.decodeStream(in);
            qrCache.put(id, b);
        } catch (Exception ignored) {}
        return b;
    }
}
