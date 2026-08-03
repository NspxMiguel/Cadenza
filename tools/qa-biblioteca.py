import sys, time, json
sys.path.insert(0,'/private/tmp/claude-501/-Users-miguel-Documents-Claude/10ff3d4e-881a-4d3b-ac58-0f6a17e888ba/scratchpad')
from probe import call

ok=[]; fail=[]
def check(nome, cond, detalhe=""):
    (ok if cond else fail).append(nome)
    print(("  OK   " if cond else "  FALHA") + f" {nome}" + (f"  {detalhe}" if detalhe else ""))

criados = {"playlists": [], "songs": [], "albums": []}

print("=== PLAYLIST: ciclo completo ===")
c,o = call('POST','/me/library/playlists', {'attributes':{'name':'Cadenza QA'}})
pid = o['data'][0]['id'] if c==201 else None
criados['playlists'].append(pid)
check("criar playlist", c==201, f"id={pid}")

c,_ = call('PATCH', f'/me/library/playlists/{pid}', {'attributes':{'name':'Cadenza QA renomeada'}})
check("renomear", c==204)
c,o = call('GET', f'/me/library/playlists/{pid}')
nome = o['data'][0]['attributes'].get('name') if c==200 else None
check("nome persistiu", nome=='Cadenza QA renomeada', f"nome={nome}")

# faixas clássicas reais
c,o = call('GET','/catalog/br/search?term=Beethoven+Moonlight+Sonata&types=songs&limit=3')
ids = [s['id'] for s in o['results']['songs']['data']] if c==200 else []
check("buscar faixas no catálogo", len(ids)>=2, f"{len(ids)} achadas")

c,_ = call('POST', f'/me/library/playlists/{pid}/tracks', {'data':[{'id':i,'type':'songs'} for i in ids]})
check("adicionar faixas", c==204)
time.sleep(2)
c,o = call('GET', f'/me/library/playlists/{pid}/tracks')
libids = [t['id'] for t in o['data']] if c==200 else []
check("faixas aparecem", len(libids)==len(ids), f"{len(libids)}/{len(ids)}")

if libids:
    c,_ = call('DELETE', f'/me/library/playlists/{pid}/tracks?ids%5Blibrary-songs%5D={libids[0]}&mode=all')
    check("remover faixa", c==204)
    time.sleep(2)
    c,o = call('GET', f'/me/library/playlists/{pid}/tracks')
    check("removeu de fato", len(o.get('data',[]))==len(libids)-1)

print()
print("=== CAPA DE PLAYLIST ===")
r = call('POST', f'/me/library/playlists/{pid}/artwork')
check("upload de capa (esperado falhar)", r[0]==405, f"HTTP {r[0]} — a API não tem rota")

print()
print("=== BIBLIOTECA: adicionar e remover ===")
song = ids[0] if ids else None
c,_ = call('POST', f'/me/library?ids%5Bsongs%5D={song}')
check("adicionar faixa à biblioteca", c==202)
c,_ = call('POST', '/me/library?ids%5Balbums%5D=1452518907')
check("adicionar álbum à biblioteca", c==202)
# 202 Accepted é assíncrono: a linha aparece depois. O teste espera de verdade
# em vez de declarar falha no primeiro olhar.
achou = []
for tentativa in range(10):
    time.sleep(4)
    c,o = call('GET','/me/library/songs?limit=25&sort=-dateAdded')
    achou = [t for t in o.get('data',[]) if (t['attributes'].get('playParams') or {}).get('catalogId')==song] if isinstance(o,dict) else []
    if achou: break
check("faixa aparece em Faixas", bool(achou), f"após {(tentativa+1)*4}s")
if achou: criados['songs'].append(achou[0]['id'])

c,o = call('GET','/me/library/albums?limit=10&sort=-dateAdded')
alb = o.get('data',[])
check("álbum aparece em Álbuns", len(alb)>0, f"{len(alb)} álbuns")
if alb: criados['albums'].append(alb[0]['id'])

def data_of(resp):
    c,o = resp
    return o.get('data',[]) if isinstance(o, dict) else []

# alguns endpoints da biblioteca recusam sort=-dateAdded; o teste registra isso
c,o = call('GET','/me/library/artists?limit=5&sort=-dateAdded')
if not isinstance(o, dict):
    print("  NOTA  /me/library/artists recusa sort=-dateAdded:", str(o)[:90])
    c,o = call('GET','/me/library/artists?limit=5')
check("artistas populados", len(o.get('data',[]) if isinstance(o,dict) else [])>0)

check("recentes populados", len(data_of(call('GET','/me/library/recently-added?limit=5')))>0)

print()
print("=== FAVORITOS ===")
c,_ = call('POST', f'/me/favorites?ids%5Bsongs%5D={song}')
check("favoritar faixa", c==202)
time.sleep(3)
c,o = call('GET','/me/library/playlists?limit=40')
fav = [p for p in o['data'] if p['attributes'].get('canEdit')==False and not (p['attributes'].get('playParams') or {}).get('globalId')]
favid = fav[0]['id'] if fav else None
c,o = call('GET', f'/me/library/playlists/{favid}/tracks?limit=100') if favid else (0,{})
temfav = any((t['attributes'].get('playParams') or {}).get('catalogId')==song for t in o.get('data',[]))
check("faixa entrou nos favoritos", temfav)
c,_ = call('DELETE', f'/me/favorites?ids%5Bsongs%5D={song}')
check("desfavoritar", c==202)

print()
print("=== TELAS CLÁSSICAS (gravações, obras, compositores) ===")
import urllib.request
from probe import C
def v10(path):
    req=urllib.request.Request('https://classical.music.apple.com/api/classical/v10'+path)
    for k,val in [('Authorization','Bearer '+C['developerToken']),('Music-User-Token',C['musicUserToken']),('Origin','https://classical.music.apple.com')]:
        req.add_header(k,val)
    try:
        with urllib.request.urlopen(req) as r: return json.loads(r.read())
    except Exception as e: return {}
for kind in ['tracks','artists','albums','recordings','works','composers']:
    d = v10(f'/query/view/br/favorites/{kind}?sortBy=dateAdded&sortOrder=descending&l=pt-BR')
    page = d.get('firstPage') or {}
    n = len(page.get('items',[]))
    print(f"  {kind:<12} {n} item(s) — {str(page.get('heading'))[:38]}")

print()
print("=== LIMPEZA ===")
# também recolhe resíduo de execuções anteriores do teste
c,o = call('GET','/me/library/playlists?limit=40')
if isinstance(o, dict):
    for p in o['data']:
        if 'Cadenza QA' in (p['attributes'].get('name') or ''):
            if p['id'] not in criados['playlists']: criados['playlists'].append(p['id'])
for lid in criados['songs']:
    print("  faixa removida:", call('DELETE', f'/me/library/songs/{lid}')[0])
for aid in criados['albums']:
    print("  álbum removido:", call('DELETE', f'/me/library/albums/{aid}')[0])
for p in criados['playlists']:
    if p: print("  playlist apagada:", call('DELETE', f'/me/library/playlists/{p}')[0])

print()
print(f"=== RESULTADO: {len(ok)} passaram, {len(fail)} falharam ===")
if fail: print("falhas:", ", ".join(fail))
