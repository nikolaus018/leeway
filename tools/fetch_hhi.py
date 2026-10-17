#!/usr/bin/env python3
"""Downloads the Croatian Hydrographic Institute's (HHI) open datasets for the chart packs.

    python3 tools/fetch_hhi.py

They come from HHI's public ArcGIS WFS services (listed in the national spatial data catalogue,
geoportal.nipp.hr) as GeoJSON into tools/.hhi-cache/, where build_vector.py picks them up:

    coast_*.geojson   coastline by county
    sea.geojson       named sea areas (regions, subregions, microregions)
    tss.geojson       traffic separation schemes
    cable_*.geojson   offshore power and telecommunication cables
    pipe_*.geojson    offshore gas, oil, water and outfall pipelines
    platform.geojson  offshore platforms

Licence: no restrictions with attribution (https://www.hhi.hr/dokumenti/uvjeti-pristupa-i-koristenja).
Standard library only.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

BASE = "https://dservices8.arcgis.com/tDYJmhP975urQUZt/arcgis/services"
CACHE = Path(__file__).resolve().parent / ".hhi-cache"
SERVICES = {
    "coast_IZ": "Obalna_crta_IZ_WFS",
    "coast_PGZ": "Obalna_crta_PGZ_WFS",
    "coast_LSZ": "Obalna_crta_LSZ",
    "coast_ZZ": "Obalna_crta_ZZ_WFS",
    "coast_SKZ": "Obalna_crta_SKZ_WFS",
    "coast_SDZ": "Obalna_crta_SDZ_WFS",
    "coast_DNZ": "Obalna_crta_DNZ_WFS",
    "sea": "morska_podrucja_v2_WFS",
    "tss": "TSS_Hrvatska_WFS",
    "cable_power": "Kl_1101_EE_WEB_WFS",
    "cable_telecom": "Kl_2103_EK_WEB_WFS",
    "pipe_gas": "Kl_4101_PL_WEB_WFS",
    "pipe_oil": "Kl_5101_NF_WEB_WFS",
    "pipe_water": "Kl_6101_VC_WEB_WFS",
    "pipe_outfall": "Kl_7101_OD_WEB_WFS",
    "platform": "Kl_4104_PL_WEB_WFS",
}


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "leeway-chart-builder/1.0"})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


def main():
    CACHE.mkdir(exist_ok=True)
    for name, service in SERVICES.items():
        capabilities = get(f"{BASE}/{service}/WFSServer?service=WFS&request=GetCapabilities").decode()
        layer = re.search(r"<(?:wfs:)?Name>([^<]+)</(?:wfs:)?Name>", capabilities)
        if not layer:
            sys.exit(f"{name}: no layer in the capabilities of {service}")
        data = get(f"{BASE}/{service}/WFSServer?service=WFS&version=2.0.0&request=GetFeature"
                   f"&typeNames={layer.group(1)}&outputFormat=GEOJSON&srsName=EPSG:4326")
        count = len(json.loads(data)["features"])
        (CACHE / f"{name}.geojson").write_bytes(data)
        print(f"{name}: {count} features, {len(data) / 1e6:.1f} MB", flush=True)


if __name__ == "__main__":
    main()
