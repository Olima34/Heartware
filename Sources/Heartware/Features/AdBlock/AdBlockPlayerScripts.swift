import Foundation
import JavaScriptCore

// What the ad-free player puts in the pages it shows (WKUserScript, page world, before the sites' own scripts), and the
// blocking rules WebKit applies to its requests (WKContentRuleList). Tested on real videos and lives in a WebKit test bench:
// YouTube without the scripts showed two ads (≈ 12 s) before the video, none with them; Twitch's ad breaks are swapped
// for the same live asked for as another player type (embed, popout, site: no ad, same quality), or stripped.
enum AdBlockPlayerScripts {
    /// YouTube: the ad fields removed from every player response, the trick that hides untouched functions in a fresh frame
    /// defeated, the ad spots of the pages hidden, and any ad that still starts muted and sent to its end.
    static let youtube = #"""
    (() => {
      'use strict';
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname) || window.__cmcAdFree) return;
      window.__cmcAdFree = true;
      const post = (type, extra) => {
        try { window.webkit.messageHandlers.hw.postMessage(Object.assign({ type, site: 'youtube' }, extra || {})); } catch (e) {}
      };
      const AD_KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams', 'adBreakParams'];
      const strip = (o) => {
        if (!o || typeof o !== 'object') return false;
        let hit = false;
        for (const k of AD_KEYS) if (Object.prototype.hasOwnProperty.call(o, k)) { delete o[k]; hit = true; }
        if (o.playerResponse && strip(o.playerResponse)) hit = true;
        if (Array.isArray(o)) for (const item of o) if (item && item.playerResponse && strip(item.playerResponse)) hit = true;
        return hit;
      };
      // One count per video whose ads were removed.
      const counted = new Set();
      const cleaned = (o) => {
        if (strip(o)) {
          const d = o.videoDetails || (o.playerResponse && o.playerResponse.videoDetails) || {};
          const id = d.videoId || new URLSearchParams(location.search).get('v') || location.pathname;
          if (!counted.has(id)) { counted.add(id); post('ad', { id }); }
        }
        return o;
      };

      // A native timer of about 15 to 17 s the player sets when the ads are missing: it fires at once.
      const setTimer = window.setTimeout;
      window.setTimeout = function (fn, delay, ...rest) {
        if (typeof fn === 'function' && delay >= 14000 && delay <= 18000 && String(fn).includes('[native code]')) delay = 17;
        return setTimer.call(this, fn, delay, ...rest);
      };
      // YouTube takes untouched copies of these functions from a fresh frame: that frame gets the filtered ones.
      const patchRealm = (w) => {
        try {
          if (!w || w === window || w.__cmcPatched) return;
          w.__cmcPatched = true;
          w.setTimeout = window.setTimeout;
          w.fetch = window.fetch;
          w.JSON.parse = JSON.parse;
          w.Request = window.Request;
          w.Response.prototype.json = Response.prototype.json;
        } catch (e) {}
      };
      for (const name of ['appendChild', 'insertBefore', 'replaceChild']) {
        const original = Node.prototype[name];
        Node.prototype[name] = function (node) {
          const result = original.apply(this, arguments);
          try {
            if (node instanceof HTMLIFrameElement) patchRealm(node.contentWindow);
            else if (node && node.querySelectorAll) for (const f of node.querySelectorAll('iframe')) patchRealm(f.contentWindow);
          } catch (e) {}
          return result;
        };
      }

      // The response written in the page, and every one the player reads afterwards.
      let initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true, get() { return initial; }, set(v) { initial = cleaned(v); }
        });
      } catch (e) {}
      const parse = JSON.parse;
      JSON.parse = function (text, reviver) {
        const value = parse.call(this, text, reviver);
        if (value && typeof value === 'object' && (value.playabilityStatus || value.playerResponse || value.adPlacements)) cleaned(value);
        return value;
      };
      const json = Response.prototype.json;
      Response.prototype.json = async function () {
        const value = await json.call(this);
        if (/\/youtubei\/v1\/(player|next|reel)/.test(this.url || '')) cleaned(value);
        return value;
      };

      // The ad spots of the pages, hidden before they show.
      const css = `
        ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer,
        ytd-promoted-video-renderer, ytd-banner-promo-renderer, ytd-statement-banner-renderer, ytd-companion-slot-renderer,
        ytd-player-legacy-desktop-watch-ads-renderer, ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"],
        #masthead-ad, #player-ads, #panels > ytd-ads-engagement-panel-content-renderer, .ytd-merch-shelf-renderer,
        ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer), ytd-rich-section-renderer:has(ytd-statement-banner-renderer),
        .ytp-ad-overlay-container, .ytp-ad-message-container, .ytp-suggested-action,
        tp-yt-paper-dialog:has(ytd-enforcement-message-view-model), ytd-enforcement-message-view-model { display: none !important; }`;
      const addStyle = () => {
        const s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      if (document.documentElement) addStyle(); else document.addEventListener('readystatechange', addStyle, { once: true });

      // An ad that still starts: silent, sent to its end, skipped. A video held back by the server: said, then released.
      let inAd = false, weMuted = false, stuck = 0, held = false;
      setInterval(() => {
        if (document.hidden) return;
        const player = document.getElementById('movie_player');
        const video = player && player.querySelector('video');
        const showing = !!(player && player.classList.contains('ad-showing'));
        if (showing && video) {
          if (!video.muted) { video.muted = true; weMuted = true; }
          if (isFinite(video.duration) && video.duration > 0) video.currentTime = video.duration;
          for (const b of document.querySelectorAll('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern')) b.click();
          if (!inAd) post('skipped');
        } else if (inAd && video && weMuted) {
          video.muted = false;
          weMuted = false;
        }
        inAd = showing;
        if (player && location.pathname === '/watch' && typeof player.getStatsForNerds === 'function') {
          try {
            const st = player.getStatsForNerds();
            const waiting = st && st.resolution === '0x0' && String(st.buffer_health_seconds).startsWith('0.00');
            stuck = waiting ? stuck + 1 : 0;
            if (stuck === 4 && !held) { held = true; post('held'); }
            if (!waiting && held) { held = false; post('released'); }
          } catch (e) {}
        }
        const wall = document.querySelector('ytd-enforcement-message-view-model');
        if (wall) {
          const dialog = wall.closest('tp-yt-paper-dialog');
          if (dialog) dialog.remove();
          const v = document.querySelector('video');
          if (v && v.paused) v.play().catch(() => {});
        }
      }, 400);
    })();
    """#

    /// Twitch: its video worker rebuilt with a filter in front of its fetch. A media playlist with ad segments is replaced
    /// by the same live asked for as another player type (often without ads), or stripped of its ad segments.
    static let twitch = #"""
    (() => {
      'use strict';
      if (!/(^|\.)twitch\.tv$/.test(location.hostname) || window.__cmcTwitch) return;
      window.__cmcTwitch = true;
      const post = (type, extra) => {
        try { window.webkit.messageHandlers.hw.postMessage(Object.assign({ type, site: 'twitch' }, extra || {})); } catch (e) {}
      };
      const channel = new BroadcastChannel('hw-twitch');
      channel.onmessage = (e) => post(e.data.type, e.data);

      function filter() {
        const report = new BroadcastChannel('hw-twitch');
        const realFetch = self.fetch;
        const CLIENT_ID = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
        const PLAYER_TYPES = ['embed', 'popout', 'site', 'autoplay'];
        let login = null, usherURL = null, breakStart = 0;
        const resolutions = {};
        const hasAd = (t) => /stitched-ad|X-TV-TWITCH-AD|twitch-stitched-ad|#EXTINF:[\d.]+,(?!live)[^\n]*\|/i.test(t);
        const parseMaster = (t, base) => {
          const out = [], lines = t.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].startsWith('#EXT-X-STREAM-INF') && lines[i + 1]) {
              out.push({ res: (lines[i].match(/RESOLUTION=(\d+x\d+)/) || [])[1] || 'audio', url: new URL(lines[i + 1].trim(), base).href });
            }
          }
          return out;
        };
        const strip = (t) => {
          const lines = t.split('\n'), out = [];
          for (let i = 0; i < lines.length; i++) {
            const l = lines[i];
            if (/^#EXT-X-DATERANGE.*(stitched-ad|twitch-stitched-ad)/i.test(l) || /^#EXT-X-TWITCH-PREFETCH/.test(l)) continue;
            if (l.startsWith('#EXTINF') && !/,live/i.test(l)) { i++; continue; }
            out.push(l);
          }
          return out.join('\n');
        };
        async function token(playerType) {
          const query = 'query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!) { streamPlaybackAccessToken(channelName: $login, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isLive) { value signature __typename } videoPlaybackAccessToken(id: $vodID, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isVod) { value signature __typename } }';
          const r = await realFetch('https://gql.twitch.tv/gql', {
            method: 'POST', headers: { 'Client-ID': CLIENT_ID, 'Content-Type': 'text/plain;charset=UTF-8' },
            body: JSON.stringify({ operationName: 'PlaybackAccessToken_Template', query, variables: { isLive: true, login, isVod: false, vodID: '', playerType } })
          });
          const j = await r.json();
          return j && j.data && j.data.streamPlaybackAccessToken;
        }
        async function backup(mediaURL) {
          if (!login || !usherURL) return null;
          for (const type of PLAYER_TYPES) {
            try {
              const t = await token(type);
              if (!t) continue;
              const u = new URL(usherURL);
              u.searchParams.set('sig', t.signature);
              u.searchParams.set('token', t.value);
              u.searchParams.set('p', String(Math.floor(Math.random() * 1e7)));
              const variants = parseMaster(await (await realFetch(u.href)).text(), u.href);
              const pick = variants.find((v) => v.res === resolutions[mediaURL]) || variants.find((v) => v.res !== 'audio') || variants[0];
              if (!pick) continue;
              const media = await (await realFetch(pick.url)).text();
              if (!hasAd(media)) return { type, text: media };
            } catch (e) {}
          }
          return null;
        }
        self.fetch = async function (input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          if (!/\.m3u8/.test(url)) return realFetch.apply(this, arguments);
          const response = await realFetch.apply(this, arguments);
          try {
            if (/usher\.ttvnw\.net\/api\/(v\d+\/)?channel\/hls\//.test(url)) {
              login = decodeURIComponent((url.match(/\/hls\/([^.?/]+)\.m3u8/) || [])[1] || '') || login;
              usherURL = url;
              for (const v of parseMaster(await response.clone().text(), url)) resolutions[v.url] = v.res;
              return response;
            }
            const text = await response.clone().text();
            if (!hasAd(text)) {
              if (breakStart) { report.postMessage({ type: 'adbreak-end', seconds: Math.round((Date.now() - breakStart) / 1000) }); breakStart = 0; }
              return response;
            }
            if (!breakStart) { breakStart = Date.now(); report.postMessage({ type: 'adbreak' }); }
            const b = await backup(url);
            report.postMessage({ type: b ? 'swap' : 'strip', playerType: b ? b.type : null });
            return new Response(b ? b.text : strip(text), { status: response.status, statusText: response.statusText, headers: response.headers });
          } catch (e) {
            return response;
          }
        };
      }

      const source = (src) => {
        try {
          if (!src.startsWith('blob:' + location.origin) && !src.startsWith(location.origin)) return null;
          const x = new XMLHttpRequest();
          x.open('GET', src, false);
          x.send();
          const text = x.responseText || '';
          return /wasmworker|amazon-ivs|ivs-worker/i.test(text) ? text : null;
        } catch (e) { return null; }
      };
      const OriginalWorker = window.Worker;
      window.Worker = class extends OriginalWorker {
        constructor(url, options) {
          const src = new URL(String(url), location.href).href;
          const text = source(src);
          if (text) super(URL.createObjectURL(new Blob([`(${filter.toString()})();\n` + text], { type: 'text/javascript' })), options);
          else super(url, options);
        }
      };
      const css = '[data-a-target="video-ad-label"], [data-a-target="video-ad-countdown"], [data-test-selector="sad-overlay"], .stream-display-ad__wrapper, [data-test-selector="display-ad"] { display: none !important; }';
      const addStyle = () => { const s = document.createElement('style'); s.textContent = css; (document.head || document.documentElement).appendChild(s); };
      if (document.documentElement) addStyle(); else document.addEventListener('readystatechange', addStyle, { once: true });
    })();
    """#

    /// France.tv: before a video with ads, its player (`magnetoscope.isAdserverReachable`) fetches a dummy ad request from
    /// FreeWheel (network 000000, asset ABC123) and walls the video (« Un bloqueur de publicités empêche le visionnage »)
    /// when that fetch fails; a timeout passes. The rules, and often the Mac's DNS, stop that server: the page is told
    /// « nothing to serve » (204) at once, without the request leaving the Mac. FreeWheel's SDK and its ads stay blocked by
    /// the rules, and the player then shows the programme alone. One count per video page.
    static let francetv = #"""
    (() => {
      'use strict';
      if (!/(^|\.)france\.tv$/.test(location.hostname) || window.__cmcFranceTV) return;
      window.__cmcFranceTV = true;
      const post = (type, extra) => {
        try { window.webkit.messageHandlers.hw.postMessage(Object.assign({ type, site: 'francetv' }, extra || {})); } catch (e) {}
      };
      // FreeWheel's ad requests (/ad/g/), on any of its servers; its SDK (/libs/) is left to the rules.
      const adRequest = /^(?:https?:)?\/\/(?:[a-z0-9-]+\.)*fwmrm\.net(?::\d+)?\/ad\/g\//i;
      const counted = new Set();
      const realFetch = window.fetch;
      window.fetch = function (input) {
        const url = String((input && input.url) || input);
        if (!adRequest.test(url)) return realFetch.apply(this, arguments);
        if (!counted.has(location.pathname)) { counted.add(location.pathname); post('ad', { id: location.pathname }); }
        return Promise.resolve(new Response(null, { status: 204, statusText: 'No Content' }));
      };
    })();
    """#

    /// Requests WebKit refuses outright in the player: ad servers, YouTube's ad and ad-tracking calls.
    static let blockedPatterns = [
        "^https?://([^/]+\\.)?doubleclick\\.net[:/]", "^https?://([^/]+\\.)?googlesyndication\\.com[:/]",
        "^https?://([^/]+\\.)?googleadservices\\.com[:/]", "^https?://adservice\\.google\\.",
        "^https?://([^/]+\\.)?youtube\\.com/pagead/", "^https?://([^/]+\\.)?youtube\\.com/api/stats/ads",
        "^https?://([^/]+\\.)?youtube\\.com/get_midroll_info", "^https?://([^/]+\\.)?youtube\\.com/pcs/activeview",
        "^https?://([^/]+\\.)?youtube\\.com/ptracking", "^https?://([^/]+\\.)?amazon-adsystem\\.com[:/]",
        "^https?://([^/]+\\.)?scorecardresearch\\.com[:/]"
    ]

    /// The video ad servers of the other sites of the player (`AdBlockPlayerSite.adHosts`), as patterns.
    static var sitePatterns: [String] {
        AdBlockPlayerSite.adHosts.map { "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: $0) + "[:/]" }
    }

    /// The rules as WebKit compiles them (a JSON list of triggers and actions).
    static var rules: String {
        var seen = Set<String>()
        let patterns = (blockedPatterns + sitePatterns).filter { seen.insert($0).inserted }
        let list = patterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: list), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The sites' scripts parse, France.tv's answers its player's dummy ad request alone (in a JavaScript engine of its
    /// own, with a pretend page), and the rules still stop FreeWheel's ads and that request.
    static func checks() -> [String] {
        var f: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { f.append("lecteur, France.tv : " + message) } }
        let scripts = AdBlockPlayerSite.all.compactMap(\.script)
        expect(scripts.count == 3 && scripts.allSatisfy { $0.contains("location.hostname") }, "chaque script de site vérifie son site")
        guard let ctx = JSContext() else { return f + ["lecteur, France.tv : pas de moteur JavaScript"] }
        @discardableResult func run(_ source: String) -> String {
            ctx.exception = nil
            let value = ctx.evaluateScript(source)?.toString() ?? ""
            if let e = ctx.exception { f.append("lecteur, France.tv : erreur JavaScript « \(e) »"); ctx.exception = nil }
            return value
        }
        for (i, script) in scripts.enumerated() {
            ctx.setObject(script, forKeyedSubscript: "src\(i)" as NSString)
            expect(run("typeof new Function(src\(i))") == "function", "script \(i + 1) illisible")
        }
        func page(_ host: String) {
            run("""
            var window = this, posted = [], out = {}, realFetch = function (input) { return 'réseau'; };
            var location = { hostname: '\(host)', pathname: '/france-2/serie/saison-1/1-episode-1.html' };
            window.webkit = { messageHandlers: { hw: { postMessage: function (m) { posted.push(m); } } } };
            function Response(body, init) { this.status = init.status; this.body = body; }
            window.fetch = realFetch;
            delete window.__cmcFranceTV;
            """)
            run(francetv)
        }
        let probe = "//7cd77.v.fwmrm.net/ad/g/1?prof=000000:ftv_html5&nw=000000&caid=ABC123&vdur=312[…]ml_lit_nowrapper,text/html_no_iframe&w=1920&h=650&flag=+cmpn"
        let asked: [(String, Bool)] = [
            (probe, true), ("https://7cd77.v.fwmrm.net/ad/g/1?nw=511351&caid=x", true), ("https://www.france.tv/api/user", false),
            ("https://mssl.fwmrm.net/libs/adm/7.17.0/AdManager.js", false), ("https://fwmrm.net.exemple.fr/ad/g/1", false),
            ("https://exemple.fr/?u=//x.fwmrm.net/ad/g/1", false), ("https://k7.ftven.fr/videos/b507d29a", false)
        ]
        page("www.france.tv")
        for (i, (url, _)) in asked.enumerated() {
            ctx.setObject(url, forKeyedSubscript: "u" as NSString)
            run("var r = fetch(u); if (r === 'réseau') out[\(i)] = 'réseau'; else r.then(function (x) { out[\(i)] = x.status; });")
        }
        // A Request object, as fetch() also takes.
        run("fetch({ url: 'https:' + '\(probe)' }).then(function (x) { out.request = x.status; });")
        for (i, (url, answered)) in asked.enumerated() {
            let got = run("String(out[\(i)])")
            expect(got == (answered ? "204" : "réseau"), "« \(url) » : \(got) au lieu de \(answered ? "204" : "réseau")")
        }
        expect(run("String(out.request)") == "204", "requête passée en objet : \(run("String(out.request)"))")
        expect(run("posted.length + ' ' + (posted[0] && posted[0].type + ' ' + posted[0].site)") == "1 ad francetv",
               "une pub comptée par vidéo : \(run("JSON.stringify(posted)"))")
        page("www.youtube.com")
        expect(run("String(window.fetch === realFetch)") == "true", "le script agit hors de France.tv")

        // The request answered in the page and FreeWheel's SDK stay blocked by the rules (nothing leaves the Mac).
        let rules = (try? JSONSerialization.jsonObject(with: Data(Self.rules.utf8))) as? [[String: Any]] ?? []
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }.compactMap { try? NSRegularExpression(pattern: $0) }
        func blocked(_ s: String) -> Bool { filters.contains { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } }
        expect(blocked("https:" + probe) && blocked("https://mssl.fwmrm.net/libs/adm/7.17.0/AdManager.js")
               && !blocked("https://static.francetv.fr/magnetoscope/main.magnetoscope.js?f"), "règles de FreeWheel")
        return f
    }
}
