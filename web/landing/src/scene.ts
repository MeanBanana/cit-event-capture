/**
 * Where every person, vehicle, weapon and number plate sits in the hero's
 * layers, as fractions of the layer image (x, y, w, h from the top left).
 * Written by the layer renderer alongside the images in public/layers/,
 * so the AI boxes in the hero stay locked to what they label.
 * mx / my: a weapon's muzzle (for the shot flashes); dir: which way it fires.
 */

export type LayerName = 'sky' | 'van' | 'ambush' | 'frame' | 'phone' | 'ground';
export type Cut = 'd' | 'm';

export type Detection = {
  kind: 'person' | 'vehicle' | 'weapon' | 'plate';
  label: string;
  layer: LayerName;
  x: number;
  y: number;
  w: number;
  h: number;
  mx?: number;
  my?: number;
  dir?: number;
  plate?: string;
};

/** Pixel size of each cut's layer images. */
export const CUT_SIZE: Record<Cut, {w: number; h: number}> = {
  d: {w: 2688, h: 1520},
  m: {w: 1080, h: 1920},
};

export const DETECTIONS: Record<Cut, Detection[]> = {
  "d": [
    {
      "kind": "vehicle",
      "label": "Vehicle 2 \u00b7 grey sedan",
      "layer": "van",
      "x": 0.6115,
      "y": 0.4334,
      "w": 0.1745,
      "h": 0.1671
    },
    {
      "kind": "vehicle",
      "label": "Vehicle 1 \u00b7 CIT van",
      "layer": "van",
      "x": 0.3925,
      "y": 0.2557,
      "w": 0.215,
      "h": 0.3994,
      "plate": "CIT 482 GP"
    },
    {
      "kind": "plate",
      "label": "Plate \u00b7 CIT 482 GP",
      "layer": "van",
      "x": 0.4742,
      "y": 0.5757,
      "w": 0.0516,
      "h": 0.0291
    },
    {
      "kind": "vehicle",
      "label": "Vehicle 3 \u00b7 dark sedan",
      "layer": "ambush",
      "x": -0.0291,
      "y": 0.582,
      "w": 0.3744,
      "h": 0.2005
    },
    {
      "kind": "person",
      "label": "Person 1",
      "layer": "ambush",
      "x": 0.212,
      "y": 0.4883,
      "w": 0.0359,
      "h": 0.143
    },
    {
      "kind": "weapon",
      "label": "Weapon 1 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.2284,
      "y": 0.5143,
      "w": 0.0523,
      "h": 0.0289,
      "mx": 0.2839,
      "my": 0.5244,
      "dir": 1
    },
    {
      "kind": "person",
      "label": "Person 2",
      "layer": "ambush",
      "x": 0.6328,
      "y": 0.4977,
      "w": 0.0544,
      "h": 0.2163
    },
    {
      "kind": "weapon",
      "label": "Weapon 2 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.5834,
      "y": 0.537,
      "w": 0.0791,
      "h": 0.0437,
      "mx": 0.5785,
      "my": 0.5571,
      "dir": -1
    },
    {
      "kind": "person",
      "label": "Person 3",
      "layer": "ambush",
      "x": 0.3011,
      "y": 0.4994,
      "w": 0.0578,
      "h": 0.2302
    },
    {
      "kind": "weapon",
      "label": "Weapon 3 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.3274,
      "y": 0.5413,
      "w": 0.0841,
      "h": 0.0465,
      "mx": 0.4168,
      "my": 0.5524,
      "dir": 1
    }
  ],
  "m": [
    {
      "kind": "vehicle",
      "label": "Vehicle 2 \u00b7 grey sedan",
      "layer": "van",
      "x": 0.7924,
      "y": 0.4231,
      "w": 0.3796,
      "h": 0.1268
    },
    {
      "kind": "vehicle",
      "label": "Vehicle 1 \u00b7 CIT van",
      "layer": "van",
      "x": 0.2116,
      "y": 0.2676,
      "w": 0.5768,
      "h": 0.3409,
      "plate": "CIT 482 GP"
    },
    {
      "kind": "plate",
      "label": "Plate \u00b7 CIT 482 GP",
      "layer": "van",
      "x": 0.4308,
      "y": 0.5407,
      "w": 0.1384,
      "h": 0.0248
    },
    {
      "kind": "vehicle",
      "label": "Vehicle 3 \u00b7 dark sedan",
      "layer": "ambush",
      "x": -0.5723,
      "y": 0.6021,
      "w": 1.0446,
      "h": 0.178
    },
    {
      "kind": "person",
      "label": "Person 1",
      "layer": "ambush",
      "x": 0.3632,
      "y": 0.446,
      "w": 0.1137,
      "h": 0.1439
    },
    {
      "kind": "weapon",
      "label": "Weapon 1 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.4148,
      "y": 0.4721,
      "w": 0.1654,
      "h": 0.0291,
      "mx": 0.5905,
      "my": 0.4823,
      "dir": 1
    },
    {
      "kind": "person",
      "label": "Person 2",
      "layer": "ambush",
      "x": 0.8162,
      "y": 0.4583,
      "w": 0.1676,
      "h": 0.2121
    },
    {
      "kind": "weapon",
      "label": "Weapon 2 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.6638,
      "y": 0.4969,
      "w": 0.2438,
      "h": 0.0429,
      "mx": 0.6486,
      "my": 0.5166,
      "dir": -1
    },
    {
      "kind": "person",
      "label": "Person 3",
      "layer": "ambush",
      "x": 0.0507,
      "y": 0.4608,
      "w": 0.1786,
      "h": 0.2261
    },
    {
      "kind": "weapon",
      "label": "Weapon 3 \u00b7 rifle",
      "layer": "ambush",
      "x": 0.1319,
      "y": 0.5019,
      "w": 0.2598,
      "h": 0.0457,
      "mx": 0.4079,
      "my": 0.5129,
      "dir": 1
    }
  ]
};
