#!/usr/bin/env node
// Erzeugt die 5-Minuten-Szene "rechenzentrum-5min" (Kapitel wie die Vertonung).
const fs = require("fs");
const path = require("path");

const preview = process.env.PREVIEW === "1";
const duration = preview ? 2.0 : 306.0;

const rows = {
  back: {
    z: -4,
    racks: [
      { x: -6, name: "node-a" },
      { x: -3, name: "Gitea" },
      { x: 0, name: "Mail" },
      { x: 3, name: "Prometheus" },
      { x: 6, name: "Karma" },
    ],
  },
  front: {
    z: 4,
    racks: [
      { x: -6, name: "node-b" },
      { x: -3, name: "node-c" },
      { x: 0, name: "Backup" },
      { x: 3, name: "Netz" },
      { x: 6, name: "Gateway" },
    ],
  },
};

const objects = [];

// Boden und Rückwand, matter als zuvor (weniger Spiegel).
objects.push({
  type: "plane",
  position: [0, 0, 0],
  size: [30, 24],
  color: "#151A22",
});
objects.push({
  type: "plane",
  position: [0, 3, -9],
  size: [30, 6],
  color: "#0B0E13",
  rotation: [Math.PI / 2, 0, 0],
});

// Bodenraster (grob, damit Objektbudget für Rackdetails bleibt).
for (let z = -8; z <= 8; z += 4) {
  objects.push({
    type: "box",
    position: [0, 0.006, z],
    size: [26, 0.01, 0.02],
    color: "#253143",
  });
}
for (let x = -12; x <= 12; x += 4) {
  objects.push({
    type: "box",
    position: [x, 0.006, 0],
    size: [0.02, 0.01, 16],
    color: "#253143",
  });
}

// Deckenleisten.
for (const z of [-2.5, 2.5]) {
  objects.push({
    type: "box",
    position: [0, 4.3, z],
    size: [18, 0.05, 0.22],
    color: "#DCE6FF",
    emissive: true,
    emissiveIntensity: 2.2,
  });
}


for (const [rowName, row] of Object.entries(rows)) {
  for (const rack of row.racks) {
    const inner = row.z < 0 ? 1 : -1; // Richtung Gang
    // Rackkorpus.
    objects.push({
      type: "box",
      position: [rack.x, 1.3, row.z],
      size: [1.7, 2.6, 1.2],
      color: "#252E3C",
    });
    // Seitliche Kabelkanäle.
    for (const side of [-0.78, 0.78]) {
      objects.push({
        type: "box",
        position: [rack.x + side, 1.3, row.z + inner * 0.62],
        size: [0.1, 2.3, 0.08],
        color: "#161D28",
      });
    }
    // Serverblenden mit Lüftungsschlitz und zwei Status-LEDs.
    for (let unit = 0; unit < 8; unit += 1) {
      const y = 0.38 + unit * 0.27;
      const faceZ = row.z + inner * 0.62;
      objects.push({
        type: "box",
        position: [rack.x, y, faceZ],
        size: [1.42, 0.2, 0.06],
        color: unit % 2 === 0 ? "#333E50" : "#2B3546",
      });
      objects.push({
        type: "box",
        position: [rack.x, y, faceZ + inner * 0.035],
        size: [1.0, 0.09, 0.02],
        color: "#1A2230",
      });
      objects.push({
        type: "sphere",
        position: [rack.x + 0.58, y, faceZ + inner * 0.05],
        radius: 0.022,
        color: "#62E39B",
        emissive: true,
        emissiveIntensity: 4,
      });
      objects.push({
        type: "sphere",
        position: [rack.x + 0.5, y, faceZ + inner * 0.05],
        radius: 0.022,
        color: "#4E8FE8",
        emissive: true,
        emissiveIntensity: 3,
      });
    }
    // ToR-Switch über den Servern.
    const topZ = row.z + inner * 0.62;
    objects.push({
      type: "box",
      position: [rack.x, 2.42, topZ],
      size: [1.44, 0.1, 0.1],
      color: "#1E2735",
    });
    for (let led = 0; led < 4; led += 1) {
      objects.push({
        type: "sphere",
        position: [rack.x - 0.45 + led * 0.3, 2.42, topZ + inner * 0.07],
        radius: 0.018,
        color: led % 2 === 0 ? "#62E39B" : "#E8C46A",
        emissive: true,
        emissiveIntensity: 4,
      });
    }
    // Beschriftung.
    objects.push({
      type: "text",
      text: rack.name,
      position: [rack.x, 2.8, row.z + inner * 0.95],
      size: 0.24,
      color: "#E6F0FF",
      billboard: true,
    });
    // Datenkabel zur Mittelachse.
    objects.push({
      type: "box",
      position: [rack.x, 0.03, row.z / 2],
      size: [0.06, 0.02, Math.abs(row.z)],
      color: rowName === "back" ? "#5B8DEF" : "#4FA37A",
      emissive: true,
      emissiveIntensity: 0.6,
    });
  }
}

// Kamerafahrt: Kapitelzeiten aus der Vertonung.
const fullPath = [
  { t: 0, position: [2.5, 2.0, 2.8], target: [0, 1.4, -4] },
  { t: 10, position: [1.2, 2.3, 1.8], target: [0, 1.4, -4] },
  { t: 23, position: [0, 2.8, 0], target: [0, 1.4, 0] },
  { t: 30, position: [7.2, 2.6, -2.4], target: [6, 1.5, 4] },
  { t: 45, position: [4.2, 2.5, -2.2], target: [3, 1.5, 4] },
  { t: 60, position: [0.8, 2.6, 2.6], target: [0, 1.5, -4] },
  { t: 76, position: [-4.8, 2.5, 2.2], target: [-6, 1.5, -4] },
  { t: 90, position: [-7.6, 2.2, 2.4], target: [-6, 1.5, -4] },
  { t: 105, position: [-4.2, 2.0, 2.6], target: [-6, 1.5, -4] },
  { t: 125, position: [-6, 2.5, -2.4], target: [-6, 1.5, 4] },
  { t: 140, position: [-7.4, 2.2, -2.2], target: [-6, 1.5, 4] },
  { t: 155, position: [-4.6, 2.0, -2.4], target: [-6, 1.5, 4] },
  { t: 169, position: [-4.0, 2.4, -2.4], target: [-3, 1.5, 4] },
  { t: 185, position: [-1.6, 2.1, -2.6], target: [-3, 1.5, 4] },
  { t: 200, position: [-2.0, 1.9, -2.2], target: [-3, 1.5, 4] },
  { t: 210, position: [0.6, 2.5, 2.6], target: [3, 1.5, -4] },
  { t: 225, position: [4.6, 2.2, 2.4], target: [3, 1.5, -4] },
  { t: 240, position: [6.6, 2.1, 2.6], target: [6, 1.5, -4] },
  { t: 252, position: [3, 3.0, 2], target: [0, 1.6, 0] },
  { t: 270, position: [0, 2.8, 2.8], target: [0, 1.5, 0] },
  { t: 289, position: [0, 3.0, 2.6], target: [0, 1.5, -4] },
  { t: 300, position: [0, 3.2, 1.8], target: [0, 1.4, -4] },
  { t: 306, position: [0, 3.4, 1.2], target: [0, 1.35, -4] },
];

const path3D = preview
  ? [
      { t: 0, position: [-1.8, 2.0, -0.8], target: [-3, 1.5, 4] },
      { t: 2, position: [-1.8, 2.0, -0.8], target: [-3, 1.5, 4] },
    ]
  : fullPath;

const scene = {
  version: 1,
  width: 1920,
  height: 1080,
  fps: 30,
  duration,
  background: "#06080C",
  camera: {
    position: fullPath[0].position,
    target: fullPath[0].target,
    fov: 42,
    path: path3D,
  },
  // Pflichtfeld; wird durch `lights` ersetzt.
  light: { position: [0, 10, 0], intensity: 0, color: "#FFFFFF" },
  lights: [
    { type: "ambient", position: [0, 0, 0], intensity: 600, color: "#C8D6E8" },
    {
      type: "directional",
      position: [6, 14, 6],
      target: [0, 0, 0],
      intensity: 1000,
      color: "#FFFFFF",
    },
    { type: "omni", position: [0, 2.7, 0], intensity: 900, color: "#B9CCE8" },
    { type: "omni", position: [-6, 3.2, -4], intensity: 520, color: "#6E8FC0" },
    { type: "omni", position: [3, 3.2, -4], intensity: 420, color: "#6FA98C" },
    { type: "omni", position: [0, 3.4, 4], intensity: 360, color: "#C9A46A" },
  ],
  objects,
};

const out = path.join(__dirname, "..", "config/scenes/rechenzentrum-5min.json");
fs.writeFileSync(out, JSON.stringify(scene, null, 2) + "\n");
console.log("Objekte:", objects.length, "Dauer:", duration);
