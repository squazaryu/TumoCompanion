"""Check Swift wire compatibility against actual published Tumoflip C code.

Usage: python3 scripts/test_field_native_interop.py /path/to/firmware-checkout
All fixtures are synthetic and confined to TemporaryDirectory.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

app = Path(__file__).resolve().parents[1]
firmware = Path(sys.argv[1]).resolve()
native = (firmware / "lib/subghz/subghz_setting.c").read_text()
table = native.split("subghz_frequency_list[] = {", 1)[1].split("};", 1)[0]
table = re.sub(r"/\*.*?\*/", "", table, flags=re.S)
frequencies = {int(value) for value in re.findall(r"\b[0-9]{9}\b", table)}
swift = (app / "Sources/Features/FieldWorkflows/SubGhzProfile.swift").read_text()
swift_table = swift.split("standardFrequencies: Set<UInt32> = [", 1)[1].split("]", 1)[0]
assert frequencies == set(map(int, re.findall(r"\d+", swift_table))), "Native standard frequency table drift"

sys.path.insert(0, str(firmware))
from tools.tumoflip.test_field_wallet import storage_native

with tempfile.TemporaryDirectory(prefix="tumo-field-interop-") as directory:
    work = Path(directory)
    # Generate with the production Swift encoder, then inspect/import in actual C.
    source = work / "main.swift"
    source.write_text('''import Foundation
let path = "/ext/subghz/Own.sub"
let payload = Data("Filetype: Flipper SubGhz Key File\\nProtocol: RAW\\nRAW_Data: 100 -100\\n".utf8)
let card = PortableObjectCard(name:"Office", notes:"Owned receiver", tags:"work", checkedAt:"manual", links:[.init(path:path,label:"Front gate")])
try PortableObjectDocument(card:card,files:[path:payload]).encoded().write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
''')
    binary, bundle = work / "encoder", work / "phone.tobj"
    sources = [app / "Sources/Features/FieldWorkflows" / name for name in ["FieldWire.swift", "PortableObject.swift"]]
    subprocess.run(["xcrun", "swiftc", *map(str, sources), str(source), "-o", str(binary)], check=True, timeout=120)
    subprocess.run([str(binary), str(bundle)], check=True, timeout=30)
    c_path = json.dumps(str(bundle))
    storage_native(r'''
int main(int argc,char**argv){
 assert(argc==2);Storage s={0};snprintf(s.root,sizeof(s.root),"%s",argv[1]);
 assert(sizeof(DeviceCard)==2556&&sizeof(FieldBundleHeader)==2888);
 assert(storage_simply_mkdir(&s,"/ext/apps_data"));
 FILE*input=fopen(PHONE_BUNDLE,"rb");assert(input);uint8_t bytes[4096];size_t n=fread(bytes,1,sizeof(bytes),input);assert(n>2888&&feof(input));assert(!fclose(input));
 File*f=storage_file_alloc(&s);assert(storage_file_open(f,"/ext/Phone.tobj",FSAM_WRITE,FSOM_CREATE_NEW));assert(storage_file_write(f,bytes,n)==n);assert(storage_file_close(f));storage_file_free(f);
 DeviceCard card;assert(field_bundle_inspect(&s,"/ext/Phone.tobj",&card,NULL,NULL));
 assert(!strcmp(card.name,"Office")&&!strcmp(card.notes,"Owned receiver")&&!strcmp(card.tags,"work")&&card.link_count==1&&!strcmp(card.labels[0],"Front gate"));
 assert(field_bundle_import(&s,"/ext/Phone.tobj","FromPhone",NULL,NULL));
 assert(library_card_load(&s,"FromPhone",&card)&&strstr(card.links[0],"/imports/FromPhone/"));
 assert(field_bundle_export(&s,&card,"/ext/Native.tobj",NULL,NULL));
 return 0;
}
''', ("field_io.h", "field_io.c", "field_bundle.h", "field_bundle.c"), prelude="#define PHONE_BUNDLE "+c_path)
print("Native frequency parity and actual C inspect/import of Swift TOB1 passed (ASan/UBSan)")
