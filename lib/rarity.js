"use strict";

// The game's real ladder, taken from the dump of
// ReplicatedStorage.Data.Rarity.Configs (RarityNumber field).
// Several distinct ids share a DisplayName (Basic->Common, Mythical->Mythic,
// Prismatic->Rainbow, Transcendent->Superior), so this indexes by the name the
// reporter actually sends.
const TIERS = [
  { rank: 1,  name: "Common",      color: "#9aa3b2", odds: "1 in 2" },
  { rank: 2,  name: "Uncommon",    color: "#3ddc84", odds: "1 in 2" },
  { rank: 2,  name: "Celestial",   color: "#00dd6b", odds: "1 in 200" },
  { rank: 2,  name: "SuperRare",   color: "#22d3ee", odds: "1 in 40" },
  { rank: 3,  name: "Rare",        color: "#3b9bff", odds: "1 in 4" },
  { rank: 4,  name: "Epic",        color: "#c471ff", odds: "1 in 10" },
  { rank: 5,  name: "Legendary",   color: "#ffa726", odds: "1 in 25" },
  { rank: 6,  name: "Mythic",      color: "#ff4d7d", odds: "1 in 100" },
  { rank: 6,  name: "Rainbow",     color: "#ff5cc8", odds: "1 in 100,000,000" },
  { rank: 6,  name: "Squishy God", color: "#cb4bff", odds: "1 in 100,000,000" },
  { rank: 7,  name: "Cosmic",      color: "#8b5cff", odds: "1 in 200" },
  { rank: 7,  name: "Exclusive",   color: "#b47cff", odds: "1 in 10,000" },
  { rank: 8,  name: "Secret",      color: "#aab2c0", odds: "1 in 100,000" },
  { rank: 8,  name: "Exotic",      color: "#ff3df2", odds: "1 in 60,000" },
  { rank: 9,  name: "Eternal",     color: "#ff35ee", odds: "1 in 100,000,000" },
  { rank: 9,  name: "Limited",     color: "#c08bff", odds: "1 in 10,000" },
  { rank: 10, name: "Divine",      color: "#f5e63d", odds: "1 in 1,000,000,000" },
  { rank: 10, name: "Superior",    color: "#c3ffff", odds: "1 in 100,000" },
  { rank: 11, name: "Titan",       color: "#ff5252", odds: "1 in 10,000,000,000" },
];

const BY_KEY = new Map();
for (const t of TIERS) BY_KEY.set(t.name.toLowerCase(), t);
// aliases the game uses internally, which may arrive untranslated
BY_KEY.set("basic", BY_KEY.get("common"));
BY_KEY.set("mythical", BY_KEY.get("mythic"));
BY_KEY.set("prismatic", BY_KEY.get("rainbow"));
BY_KEY.set("transcendent", BY_KEY.get("superior"));
BY_KEY.set("brainrotgod", BY_KEY.get("squishy god"));

const key = (name) => String(name == null ? "" : name).trim().toLowerCase();

// 0 = unknown. That way an unrecognised rarity never outranks a real one when
// sorting, instead of slipping to the top of the feed.
function rarityRank(name) {
  const t = BY_KEY.get(key(name));
  return t ? t.rank : 0;
}

function rarityColor(name) {
  const t = BY_KEY.get(key(name));
  return t ? t.color : "#6b7280";
}

function rarityKnown(name) {
  return BY_KEY.has(key(name));
}

// Unique names, rarest to most common: the order the dashboard and the AJ
// paint the filter chips in.
const LADDER = (() => {
  const seen = new Set();
  const out = [];
  for (const t of [...TIERS].sort((a, b) => b.rank - a.rank)) {
    if (seen.has(t.name)) continue;
    seen.add(t.name);
    out.push({ name: t.name, rank: t.rank, color: t.color, odds: t.odds });
  }
  return out;
})();

module.exports = { TIERS, LADDER, rarityRank, rarityColor, rarityKnown };
