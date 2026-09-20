#!/usr/bin/env python3
"""Refresh the small offline example library from PubChem's public PUG REST API.
No notes or user input are sent. Review the JSON diff and run ChemistryTests after refresh.
"""
import datetime
import json
from pathlib import Path
import time
import urllib.request

EXAMPLES = [
    ('water', 'Water', 962, 'A bent molecule. Oxygen is red; hydrogen is white.', True),
    ('methane', 'Methane', 297, 'Four bonds spread around carbon in a tetrahedral arrangement.', True),
    ('ammonia', 'Ammonia', 222, 'Three hydrogens form a pyramid around nitrogen.', True),
    ('carbon-dioxide', 'Carbon dioxide', 280, 'A linear molecule with two carbon–oxygen double bonds.', False),
    ('ethanol', 'Ethanol', 702, 'An alcohol: the oxygen at the end carries a hydrogen.', False),
    ('benzene', 'Benzene', 241, 'A flat, six-carbon aromatic ring. Alternating bonds are a drawing convention.', False),
    ('glycine', 'Glycine', 750, 'The simplest amino acid. This example shows its neutral form; charge depends on conditions.', False),
    ('caffeine', 'Caffeine', 2519, 'Explore two connected rings and the nitrogen and oxygen atoms.', False),
]
SYMBOLS = {1:'H', 6:'C', 7:'N', 8:'O'}

def record(cid, dimension):
    url = f'https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}/record/JSON?record_type={dimension}'
    with urllib.request.urlopen(url, timeout=45) as response:
        result = json.load(response)['PC_Compounds'][0]
    time.sleep(0.25)  # Remain below PubChem's request limit.
    return result

examples = []
for key, name, cid, detail, show_h in EXAMPLES:
    flat, spatial = record(cid, '2d'), record(cid, '3d')
    assert flat['atoms'] == spatial['atoms'] and flat['bonds'] == spatial['bonds']
    plane, space = flat['coords'][0], spatial['coords'][0]
    xy, xyz = plane['conformers'][0], space['conformers'][0]
    positions2 = {aid: (xy['x'][i], xy['y'][i]) for i, aid in enumerate(plane['aid'])}
    positions3 = {aid: (xyz['x'][i], xyz['y'][i], xyz['z'][i]) for i, aid in enumerate(space['aid'])}
    charges = {item['aid']: item['value'] for item in spatial['atoms'].get('charge', [])}
    formula = next(p['value']['sval'] for p in flat['props'] if p['urn']['label'] == 'Molecular Formula')
    conformer = next(p['value']['sval'] for p in xyz['data'] if p['urn']['label'] == 'Conformer' and p['urn']['name'] == 'ID')
    atoms = [dict(id=aid, element=SYMBOLS[element], charge=charges.get(aid, 0),
                  x2=positions2[aid][0], y2=positions2[aid][1],
                  x=positions3[aid][0], y=positions3[aid][1], z=positions3[aid][2])
             for aid, element in zip(spatial['atoms']['aid'], spatial['atoms']['element'])]
    bonds = [dict(start=a, end=b, order=o) for a, b, o in zip(spatial['bonds']['aid1'], spatial['bonds']['aid2'], spatial['bonds']['order'])]
    examples.append(dict(id=key, name=name, cid=cid, detail=detail, formula=formula,
                         showHydrogensInDrawing=show_h, conformerID=conformer,
                         retrieved=datetime.date.today().isoformat(), atoms=atoms, bonds=bonds))
    print(f'{name}: {formula}, {len(atoms)} atoms, conformer {conformer}')

path = Path(__file__).resolve().parents[1] / 'BeanNotes/Resources/Chemistry/MoleculeExamples.json'
path.write_text(json.dumps(examples, indent=2) + '\n')
