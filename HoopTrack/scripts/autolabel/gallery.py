"""
gallery.py — self-contained offline HTML review.

Renders one <canvas> per frame with bounding boxes overlaid, keyboard
navigation (j/k) and a single-key delete-flag (d). Flagged frames are
collected in localStorage and exportable as a delete_list.txt for
apply_review.py to consume.

No external JS, no CDN, no fonts — the file opens offline on any
browser.
"""

import json
from pathlib import Path


# Embedded in the generated HTML as a JS literal.
CLASS_COLORS = ["#ff6b35", "#3d9cff", "#3cdc78"]


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{{title}}</title>
<style>
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: #111;
    color: #eee;
  }
  header {
    position: sticky; top: 0;
    padding: 12px 20px;
    background: rgba(17,17,17,0.95);
    border-bottom: 1px solid #333;
    display: flex;
    gap: 16px;
    align-items: center;
    z-index: 10;
  }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; }
  header .stats { font-size: 12px; color: #888; }
  header .kbd {
    font-size: 12px;
    color: #ccc;
    padding: 2px 6px;
    border: 1px solid #444;
    border-radius: 4px;
    font-family: "SF Mono", Menlo, monospace;
  }
  button {
    background: #ff6b35;
    color: #111;
    border: 0;
    padding: 6px 12px;
    border-radius: 6px;
    font-weight: 600;
    cursor: pointer;
    font-size: 12px;
  }
  button:hover { background: #ff8557; }
  main {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
    gap: 12px;
    padding: 16px;
  }
  .frame {
    background: #1a1a1a;
    border: 2px solid transparent;
    border-radius: 8px;
    overflow: hidden;
    position: relative;
  }
  .frame.focused { border-color: #ff6b35; }
  .frame.flagged { opacity: 0.35; border-color: #e53935; }
  .frame canvas { display: block; width: 100%; height: auto; }
  .frame .caption {
    padding: 6px 10px;
    font-size: 11px;
    font-family: "SF Mono", Menlo, monospace;
    color: #aaa;
    display: flex;
    justify-content: space-between;
  }
  .frame .caption .flag-note {
    color: #e53935;
    font-weight: 600;
  }
  .legend {
    display: flex; gap: 16px; font-size: 12px;
  }
  .legend span { display: flex; align-items: center; gap: 6px; }
  .legend i {
    width: 10px; height: 10px; border-radius: 2px;
    display: inline-block;
  }
</style>
</head>
<body>
<header>
  <h1>{{title}}</h1>
  <span class="stats">{{frame_count}} frames · {{detections_total}} detections · {{drops}} unmapped drops</span>
  <span class="legend">
    <span><i style="background:#ff6b35"></i>ball</span>
    <span><i style="background:#3d9cff"></i>human</span>
    <span><i style="background:#3cdc78"></i>rim</span>
  </span>
  <span style="flex:1"></span>
  <span><span class="kbd">j</span> / <span class="kbd">k</span> move · <span class="kbd">d</span> toggle delete</span>
  <button id="exportBtn">Export delete_list.txt</button>
</header>
<main id="grid"></main>

<script>
const CLASS_COLORS = {{class_colors_json}};
const CLASS_NAMES  = {{class_names_json}};
const FRAMES       = {{frames_json}};
const RUN_ID       = {{run_id_json}};
const LS_KEY       = "autolabel_flags_" + RUN_ID;

const flagged = new Set(JSON.parse(localStorage.getItem(LS_KEY) || "[]"));
let focusIdx = 0;

function renderFrame(record, idx) {
  const wrap = document.createElement("div");
  wrap.className = "frame";
  if (flagged.has(record.image)) wrap.classList.add("flagged");

  const canvas = document.createElement("canvas");
  canvas.width = record.width;
  canvas.height = record.height;
  wrap.appendChild(canvas);

  const cap = document.createElement("div");
  cap.className = "caption";
  cap.innerHTML =
    '<span>' + record.image + '</span>' +
    '<span class="flag-note" style="display:' + (flagged.has(record.image) ? 'inline' : 'none') + '">flagged</span>';
  wrap.appendChild(cap);

  const img = new Image();
  img.onload = () => {
    const ctx = canvas.getContext("2d");
    ctx.drawImage(img, 0, 0, record.width, record.height);
    for (const det of record.detections) {
      const color = CLASS_COLORS[det.class_id] || "#fff";
      const [x1, y1, x2, y2] = det.box_px;
      ctx.lineWidth = Math.max(2, record.width / 400);
      ctx.strokeStyle = color;
      ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);

      const label = CLASS_NAMES[det.class_id] + " " + det.score.toFixed(2);
      ctx.font = Math.max(14, record.width / 60) + "px -apple-system, Segoe UI, sans-serif";
      const tw = ctx.measureText(label).width;
      const th = Math.max(14, record.width / 60) + 4;
      ctx.fillStyle = color;
      ctx.fillRect(x1, y1 - th, tw + 8, th);
      ctx.fillStyle = "#000";
      ctx.fillText(label, x1 + 4, y1 - 4);
    }
  };
  img.src = "images/" + record.image;

  wrap.addEventListener("click", () => setFocus(idx));
  return wrap;
}

function setFocus(idx) {
  const nodes = document.querySelectorAll(".frame");
  nodes.forEach(n => n.classList.remove("focused"));
  focusIdx = Math.max(0, Math.min(nodes.length - 1, idx));
  const node = nodes[focusIdx];
  node.classList.add("focused");
  node.scrollIntoView({ block: "center", behavior: "smooth" });
}

function toggleFlag(idx) {
  const rec = FRAMES[idx];
  if (flagged.has(rec.image)) flagged.delete(rec.image);
  else flagged.add(rec.image);
  localStorage.setItem(LS_KEY, JSON.stringify([...flagged]));
  const node = document.querySelectorAll(".frame")[idx];
  node.classList.toggle("flagged", flagged.has(rec.image));
  node.querySelector(".flag-note").style.display = flagged.has(rec.image) ? "inline" : "none";
}

function render() {
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  FRAMES.forEach((rec, i) => grid.appendChild(renderFrame(rec, i)));
  setFocus(0);
}

document.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;
  if (e.key === "j") { e.preventDefault(); setFocus(focusIdx + 1); }
  else if (e.key === "k") { e.preventDefault(); setFocus(focusIdx - 1); }
  else if (e.key === "d") { e.preventDefault(); toggleFlag(focusIdx); }
});

document.getElementById("exportBtn").addEventListener("click", () => {
  const text = [...flagged].sort().join("\\n") + "\\n";
  const blob = new Blob([text], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "delete_list.txt";
  a.click();
  URL.revokeObjectURL(url);
});

render();
</script>
</body>
</html>
"""


def build_review_gallery(out_dir: Path, manifest: dict, per_frame: list[dict]) -> None:
    """Render review.html next to images/ and labels/.

    per_frame: list of {image, width, height, detections: [{class_id, score, box_px, raw_label}, ...]}
    """
    frames_js = []
    for rec in per_frame:
        frames_js.append({
            "image": rec["image"],
            "width": rec["width"],
            "height": rec["height"],
            "detections": [
                {"class_id": d["class_id"], "score": d["score"], "box_px": list(d["box_px"])}
                for d in rec["detections"]
            ],
        })

    html = (HTML_TEMPLATE
        .replace("{{title}}", f"Review — {manifest['run_id']}")
        .replace("{{frame_count}}", str(manifest["frame_count"]))
        .replace("{{detections_total}}", str(manifest["detections_total"]))
        .replace("{{drops}}", str(manifest["label_drops_unmapped"]))
        .replace("{{class_colors_json}}", json.dumps(CLASS_COLORS))
        .replace("{{class_names_json}}", json.dumps(manifest["class_names"]))
        .replace("{{frames_json}}", json.dumps(frames_js))
        .replace("{{run_id_json}}", json.dumps(manifest["run_id"]))
    )
    (out_dir / "review.html").write_text(html)
