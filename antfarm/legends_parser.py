import os
import sys
import sqlite3
import xml.etree.ElementTree as ET
import glob

# Written next to the other runtime state, where tui.py reads it from.
DB_NAME = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "state", "legends.db")

def init_db(conn):
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS historical_figures (
            id INTEGER PRIMARY KEY,
            name TEXT,
            race TEXT,
            birth_year INTEGER,
            death_year INTEGER
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS relationships (
            hf_id_1 INTEGER,
            relation_type TEXT,
            hf_id_2 INTEGER,
            PRIMARY KEY (hf_id_1, relation_type, hf_id_2)
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS noble_positions (
            hf_id INTEGER,
            title TEXT,
            entity_name TEXT
        )
    """)
    c.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY,
            hf_id INTEGER,
            event_type TEXT,
            description TEXT
        )
    """)
    conn.commit()

def parse_legends_xml(xml_path, db_path):
    print(f"Parsing legends XML from: {xml_path}")
    print(f"Target SQLite DB: {db_path}")
    
    conn = sqlite3.connect(db_path)
    init_db(conn)
    
    c = conn.cursor()
    
    # We use iterparse for memory efficiency
    context = ET.iterparse(xml_path, events=("end",))
    
    count = 0
    rel_inserts = []
    hf_inserts = []
    
    for event, elem in context:
        if elem.tag == "historical_figure":
            hf_id = None
            name = None
            race = None
            birth_year = -1
            death_year = -1
            
            id_elem = elem.find("id")
            if id_elem is not None:
                hf_id = int(id_elem.text)
            
            name_elem = elem.find("name")
            if name_elem is not None:
                name = name_elem.text
            
            race_elem = elem.find("race")
            if race_elem is not None:
                race = race_elem.text
                
            by_elem = elem.find("birth_year")
            if by_elem is not None and by_elem.text:
                birth_year = int(by_elem.text)
                
            dy_elem = elem.find("death_year")
            if dy_elem is not None and dy_elem.text:
                death_year = int(dy_elem.text)
                
            if hf_id is not None:
                hf_inserts.append((hf_id, name, race, birth_year, death_year))
                
                # Check for direct relationship tags
                for tag in ["spouse", "child", "parent", "sibling"]:
                    for rel_elem in elem.findall(tag):
                        if rel_elem.text:
                            rel_inserts.append((hf_id, tag, int(rel_elem.text)))
                            
                # Check for hf_link elements (DF 0.47.x format)
                for link in elem.findall("hf_link"):
                    link_type = link.find("link_type")
                    hfid = link.find("hfid")
                    if link_type is not None and hfid is not None and link_type.text and hfid.text:
                        rel_inserts.append((hf_id, link_type.text, int(hfid.text)))
                        
                # Check for legacy histfig_links
                links = elem.find("histfig_links")
                if links is not None:
                    for link in links.findall("histfig_link"):
                        link_type = link.find("link_type") or link.find("type")
                        target = link.find("target") or link.find("target_hf_id")
                        if link_type is not None and target is not None and link_type.text and target.text:
                            rel_inserts.append((hf_id, link_type.text, int(target.text)))
            
            count += 1
            if count % 5000 == 0:
                print(f"Processed {count} historical figures...")
                
            # Clear element to free memory
            elem.clear()
            
        # Commit in batches
        if len(hf_inserts) >= 5000:
            c.executemany("INSERT OR REPLACE INTO historical_figures VALUES (?, ?, ?, ?, ?)", hf_inserts)
            hf_inserts = []
            
        if len(rel_inserts) >= 5000:
            c.executemany("INSERT OR IGNORE INTO relationships VALUES (?, ?, ?)", rel_inserts)
            rel_inserts = []
            
    if hf_inserts:
        c.executemany("INSERT OR REPLACE INTO historical_figures VALUES (?, ?, ?, ?, ?)", hf_inserts)
    if rel_inserts:
        c.executemany("INSERT OR IGNORE INTO relationships VALUES (?, ?, ?)", rel_inserts)
        
    conn.commit()
    conn.close()
    print(f"Completed! Total historical figures processed: {count}")

def find_latest_legends_xml(search_dir):
    pattern = os.path.join(search_dir, "*legends*.xml")
    files = glob.glob(pattern)
    if not files:
        # Check subdirectories
        pattern = os.path.join(search_dir, "**", "*legends*.xml")
        files = glob.glob(pattern, recursive=True)
    if not files:
        return None
    # Return newest by modification time
    return max(files, key=os.path.getmtime)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Parse Dwarf Fortress Legends XML into SQLite.")
    parser.add_argument("xml_path", nargs="?", help="Path to legends XML. If omitted, searches automatically.")
    args = parser.parse_args()
    
    xml_path = args.xml_path
    if not xml_path:
        xml_path = find_latest_legends_xml(".")
        if not xml_path:
            xml_path = find_latest_legends_xml("game")
            
    if not xml_path:
        print("Error: No legends XML file found. Please specify the path or export one in DF via 'exportlegends'.")
        sys.exit(1)
        
    # DB_NAME is already absolute; joining it to the package directory used to
    # bury the database inside antfarm/ regardless.
    os.makedirs(os.path.dirname(DB_NAME), exist_ok=True)
    parse_legends_xml(xml_path, DB_NAME)
