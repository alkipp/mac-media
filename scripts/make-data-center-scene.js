#!/usr/bin/env node
// Erzeugt die 3D-Szene "Rechenzentrum" für config/scenes/rechenzentrum.json.
const racks = [
  { x: -4.5, z: -2.5, name: "node-a", led: "#4FA37A", units: 6 },
  { x: -2.5, z: -2.5, name: "node-b", led: "#4FA37A", units: 4 },
  { x: -0.5, z: -2.5, name: "Netz", led: "#5B8DEF", units: 3 },
  { x: 1.5, z: -2.5, name: "Backup", led: "#D9A441", units: 4 },
  { x: -4.5, z: 2.5, name: "Internet", led: "#5B8DEF", units: 3 },
  { x: -2.5, z: 2.5, name: "Gitea", led: "#4FA37A", units: 5 },
  { x: -0.5, z: 2.5, name: "Monitoring", led: "#4FA37A", units: 5 },
  { x: 1.5, z: 2.5, name: "Mail", led: "#4FA37A", units: 4 },
];

const objects = [];

// Boden und Rückwand
objects.push({ type: "plane", position: [0, 0, 0], size: [24, 14], color: "#141821" });
objects.push({
  type: "plane",
  position: [0, 3, -7],
  size: [24, 6],
  color: "#0E1218",
  rotation: [Math.PI / 2, 0, 0],
});

// Bodenraster
for (let z = -5; z <= 5; z += 1) {
  objects.push({ type: "box", position: [0, 0.004, z], size: [22, 0.008, 0.012], color: "#232B38" });
}
for (let x = -10; x <= 10; x += 2) {
  objects.push({ type: "box", position: [x, 0.004, 0], size: [0.012, 0.008, 12], color: "#232B38" });
}

// Racks mit Servern und LEDs
for (const rack of racks) {
  objects.push({
    type: "box",
    position: [rack.x, 1.1, rack.z],
    size: [1.2, 2.2, 1.0],
    color: "#232A36",
  });
  const front = rack.z < 0 ? 0.53 : -0.53;
  for (let unit = 0; unit < rack.units; unit += 1) {
    const y = 0.42 + unit * 0.26;
    objects.push({
      type: "box",
      position: [rack.x, y, rack.z + front],
      size: [1.0, 0.17, 0.05],
      color: "#2E3646",
    });
    objects.push({
      type: "sphere",
      position: [rack.x + 0.42, y, rack.z + front + (rack.z < 0 ? 0.04 : -0.04)],
      radius: 0.022,
      color: rack.led,
      emissive: true,
    });
  }
  // Kabel zur Mittelachse
  objects.push({
    type: "box",
    position: [rack.x, 0.02, rack.z / 2],
    size: [0.05, 0.02, Math.abs(rack.z)],
    color: rack.led,
    emissive: true,
  });
  // Beschriftung vor dem Rack, damit sie nicht dahinter verschwindet
  const labelZ = rack.z < 0 ? rack.z + 0.72 : rack.z - 0.72;
  objects.push({
    type: "text",
    text: rack.name,
    position: [rack.x, 2.45 + ((rack.z > 0 && (rack.x === -4.5 || rack.x === -0.5)) ? 0.26 : 0), labelZ],
    size: 0.22,
    color: "#E6EAF2",
    billboard: true,
  });
}

// Titel
objects.push({
  type: "text",
  text: "Data Center",
  position: [0, 3.4, -3.2],
  size: 0.5,
  color: "#F5F5F7",
  billboard: true,
});

// Netzwerk-Kern in der Mittelachse
objects.push({
  type: "box",
  position: [0, 0.35, 0],
  size: [2.0, 0.7, 1.0],
  color: "#2B4A6B",
});
objects.push({
  type: "text",
  text: "Core · WireGuard",
  position: [0, 1.3, 0.2],
  size: 0.2,
  color: "#8FB4FF",
  billboard: true,
});

const scene = {
  version: 1,
  width: 1920,
  height: 1080,
  fps: 30,
  duration: 24.0,
  background: "#07090D",
  camera: {
    position: [7.5, 3.6, 9.5],
    target: [0, 1.2, 0],
    fov: 45,
    orbit: { degrees: 50, axis: "y" },
  },
  light: { position: [7, 11, 7], intensity: 2200, color: "#FFFFFF" },
  ambient: { intensity: 320, color: "#8FA6C8" },
  objects,
};

require("fs").writeFileSync(
  require("path").join(__dirname, "..", "config/scenes/rechenzentrum.json"),
  JSON.stringify(scene, null, 2) + "\n",
);
console.log("Objekte:", objects.length);
