// Lists Wikisource "original" editions whose author, according to Wikidata
// (P6886 / P1412), never wrote in the edition language: usually a translated
// piece whose item names the original author. Review by hand; missionaries
// and bilingual authors are frequent false positives.
//
//   node scripts/check-author-languages.js > build/suspicious-originals.tsv
const fs = require("fs"), path = require("path"), https = require("https");
const base = { "pt-BR": "pt", "zh-Hant": "zh", "zh-Hans": "zh", lzh: "zh", "zh-classical": "zh", nb: "no", nn: "no", tl: "fil" };
const norm = c => base[c] || c.toLowerCase();
const eds = [];
for (const lang of fs.readdirSync("metadata")) for (const f of fs.readdirSync(path.join("metadata", lang))) {
  const m = JSON.parse(fs.readFileSync(path.join("metadata", lang, f), "utf8"));
  if (m.source.provider === "wikisource" && m.edition.kind === "original" && m.work.author.wikidata) eds.push({ id: m.edition.editionId, lang, q: m.work.author.wikidata, author: m.work.author.name });
}
const qids = [...new Set(eds.map(e => e.q))];
const get = url => new Promise((res, rej) => https.get(url, { headers: { "user-agent": "lsr-library-tools/0.1" } }, r => { let s = ""; r.on("data", d => s += d); r.on("end", () => res(JSON.parse(s))); }).on("error", rej));
(async () => {
  const langsOf = {}; const codes = {};
  for (let i = 0; i < qids.length; i += 50) {
    const j = await get("https://www.wikidata.org/w/api.php?action=wbgetentities&ids=" + qids.slice(i, i + 50).join("|") + "&props=claims&format=json");
    for (const q in j.entities) { const c = j.entities[q].claims || {}; langsOf[q] = [...(c.P6886 || []), ...(c.P1412 || [])].map(s => s.mainsnak.datavalue && s.mainsnak.datavalue.value.id).filter(Boolean); }
  }
  const langQ = [...new Set(Object.values(langsOf).flat())];
  for (let i = 0; i < langQ.length; i += 50) {
    const j = await get("https://www.wikidata.org/w/api.php?action=wbgetentities&ids=" + langQ.slice(i, i + 50).join("|") + "&props=claims&format=json");
    for (const q in j.entities) { const c = j.entities[q].claims || {}; codes[q] = (c.P424 || []).map(s => s.mainsnak.datavalue && s.mainsnak.datavalue.value).filter(Boolean); }
  }
  let suspicious = 0;
  for (const e of eds) {
    const ls = (langsOf[e.q] || []).flatMap(q => codes[q] || []).map(norm);
    if (ls.length && !ls.includes(norm(e.lang))) { suspicious++; console.log(e.id + "\t" + e.author + "\t" + ls.join(",")); }
  }
  console.error("checked " + eds.length + " originals, " + qids.length + " authors, suspicious " + suspicious);
})();
