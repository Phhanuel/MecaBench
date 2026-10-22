// =============================================================================
// MecaBench — connecteur MCP (Model Context Protocol) pour Claude
//
// Fonction Edge Supabase "mecabench-mcp". Elle reçoit les appels de Claude,
// vérifie le jeton personnel (créé dans MecaBench > Mon compte > Accès API) et
// lit/écrit les projets via les fonctions SQL api_* (voir supabase-setup.sql),
// qui appliquent les mêmes droits que dans l'appli.
//
// Déploiement : voir README.md ("Connecteur Claude"). Désactiver "Verify JWT"
// pour cette fonction (l'authentification se fait avec le jeton MecaBench).
// Variables fournies automatiquement par Supabase : SUPABASE_URL et
// SUPABASE_SERVICE_ROLE_KEY.
//
// (Fichier volontairement en JavaScript pur : il est aussi testé sous Node.)
// =============================================================================

const SERVER_INFO = { name: 'mecabench', version: '1.3.0' };
const SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
const MAX_OUTPUT_CHARS = 150000;
const MAX_FIELD = 500;
const MAX_NODES = 2000;
const MAX_DEPTH = 12;
const INSTRUCTIONS =
  "MecaBench : outil de nomenclatures (arbres pack / produits). Un PROJET contient une base de données de PIÈCES (réf., nom, prix…), des groupes, " +
  "et des PRODUITS (arbres de nomenclature faits de packs et de pièces). Commence par list_projects, puis get_project. " +
  "Les modifications sont enregistrées dans le cloud et apparaissent en direct dans l'appli ouverte. N'invente pas de prix ni de références : demande-les à l'utilisateur.";

const TOOLS = [
  {
    name: 'list_projects',
    description: "Liste les projets accessibles (perso et équipes) avec ton rôle (owner/editor/viewer), la version, le nombre de pièces et de produits.",
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'get_project',
    description: "Lit un projet. Par défaut : pièces, groupes et produits (arbres). 'include' peut contenir : parts, groups, bruts, produits, raw (JSON brut complet).",
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string', description: 'Identifiant (uuid) du projet' },
        include: { type: 'array', items: { type: 'string', enum: ['parts', 'groups', 'bruts', 'produits', 'raw'] } },
      },
      required: ['project_id'],
      additionalProperties: false,
    },
  },
  {
    name: 'create_project',
    description: "Crée un projet (perso, ou dans une équipe si team_id est donné et que tu y es propriétaire/éditeur).",
    inputSchema: {
      type: 'object',
      properties: { title: { type: 'string' }, team_id: { type: 'string', description: "uuid de l'équipe (facultatif)" } },
      required: ['title'],
      additionalProperties: false,
    },
  },
  {
    name: 'rename_project',
    description: 'Renomme un projet.',
    inputSchema: {
      type: 'object',
      properties: { project_id: { type: 'string' }, title: { type: 'string' } },
      required: ['project_id', 'title'],
      additionalProperties: false,
    },
  },
  {
    name: 'add_parts',
    description:
      "Ajoute des pièces à la base de données du projet. Champs : reference, nom, prix (nombre, en €), matiere, categorie, pm (prix matière), va (valeur ajoutée), group (nom de groupe, ou chemin de sous-groupes « Parent > Enfant », créé si besoin), temp (case « Temp. »). " +
      "Par défaut, une pièce dont la référence existe déjà est ignorée (on_duplicate_reference='add' pour l'ajouter quand même).",
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string' },
        parts: {
          type: 'array',
          maxItems: 500,
          items: {
            type: 'object',
            properties: {
              reference: { type: 'string' }, nom: { type: 'string' }, prix: { type: ['number', 'string'] },
              matiere: { type: 'string' }, categorie: { type: 'string' }, pm: { type: ['number', 'string'] }, va: { type: ['number', 'string'] },
              group: { type: 'string' }, temp: { type: 'boolean' },
            },
            additionalProperties: false,
          },
        },
        on_duplicate_reference: { type: 'string', enum: ['skip', 'add'] },
      },
      required: ['project_id', 'parts'],
      additionalProperties: false,
    },
  },
  {
    name: 'update_part',
    description: "Modifie une pièce existante (par part_id). Champs modifiables : reference, nom, prix, matiere, categorie, pm, va, group (nom ou chemin « Parent > Enfant », créé si besoin ; '' pour retirer du groupe), temp (case « Temp. » : prix provisoire). Changer prix sans temp décoche Temp. Les produits qui utilisent la pièce sont mis à jour. Pour plusieurs pièces, utiliser update_parts.",
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string' }, part_id: { type: 'string' },
        fields: {
          type: 'object',
          properties: {
            reference: { type: 'string' }, nom: { type: 'string' }, prix: { type: ['number', 'string'] },
            matiere: { type: 'string' }, categorie: { type: 'string' }, pm: { type: ['number', 'string'] }, va: { type: ['number', 'string'] },
            group: { type: 'string' }, temp: { type: 'boolean', description: 'Case « Temp. » (prix provisoire)' },
          },
          additionalProperties: false,
        },
      },
      required: ['project_id', 'part_id', 'fields'],
      additionalProperties: false,
    },
  },
  {
    name: 'update_parts',
    description: "Modifie plusieurs pièces en un seul enregistrement. 'updates' = liste de { part_id, fields } avec les mêmes champs que update_part. Tout ou rien : si une pièce est introuvable, rien n'est modifié.",
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string' },
        updates: {
          type: 'array', maxItems: 500,
          items: {
            type: 'object',
            properties: {
              part_id: { type: 'string' },
              fields: {
                type: 'object',
                properties: {
                  reference: { type: 'string' }, nom: { type: 'string' }, prix: { type: ['number', 'string'] },
                  matiere: { type: 'string' }, categorie: { type: 'string' }, pm: { type: ['number', 'string'] }, va: { type: ['number', 'string'] },
                  group: { type: 'string' }, temp: { type: 'boolean' },
                },
                additionalProperties: false,
              },
            },
            required: ['part_id', 'fields'],
            additionalProperties: false,
          },
        },
      },
      required: ['project_id', 'updates'],
      additionalProperties: false,
    },
  },
  {
    name: 'delete_parts',
    description: "Supprime des pièces de la base de données. Refuse celles qui sont utilisées dans un produit (la réponse les liste).",
    inputSchema: {
      type: 'object',
      properties: { project_id: { type: 'string' }, part_ids: { type: 'array', items: { type: 'string' }, maxItems: 500 } },
      required: ['project_id', 'part_ids'],
      additionalProperties: false,
    },
  },
  {
    name: 'save_produit',
    description:
      "Crée un produit (ou remplace TOUT le contenu de produit_id). 'tree' = liste de BLOCS racines, sur deux niveaux comme dans l'appli. " +
      "Bloc racine : { kind: 'pack' (défaut) | 'sachet' | 'special', key (identifiant libre pour y renvoyer), reference, nom, quantity, va, children[] }. Un bloc racine n'est jamais confondu avec une pièce. " +
      "Ligne d'un bloc : soit une pièce { part_id | reference, quantity }, soit un renvoi vers un autre bloc racine { pack: <key ou nom du bloc>, quantity } (ex. un sachet dans un pack, des packs dans un pack spécial). " +
      "Une ligne sans pièce correspondante devient une ligne libre (reference/nom donnés). Une ligne ne peut pas avoir d'enfants. Un pack spécial ne peut pas être référencé. " +
      "get_project renvoie le même format (kind/key/pack), donc on peut relire, modifier et réenregistrer sans perdre les liens. Sans 'tree' avec produit_id, seuls title/notes sont modifiés.",
    inputSchema: {
      type: 'object',
      properties: {
        project_id: { type: 'string' },
        produit_id: { type: 'string', description: 'Absent = nouveau produit' },
        title: { type: 'string' },
        notes: { type: 'string' },
        tree: { type: 'array', items: { $ref: '#/$defs/node' } },
      },
      required: ['project_id'],
      additionalProperties: false,
      $defs: {
        node: {
          type: 'object',
          properties: {
            kind: { type: 'string', enum: ['pack', 'sachet', 'special'], description: 'Bloc racine uniquement' },
            key: { type: 'string', description: 'Bloc racine : identifiant pour les renvois (pack)' },
            pack: { type: 'string', description: "Ligne : renvoi vers un bloc racine (key ou nom)" },
            part_id: { type: 'string' }, reference: { type: 'string' }, nom: { type: 'string' },
            quantity: { type: ['number', 'string'] },
            va: { type: ['number', 'string'], description: 'Bloc racine : valeur ajoutée' },
            children: { type: 'array', items: { $ref: '#/$defs/node' } },
          },
          additionalProperties: false,
        },
      },
    },
  },
];

const WRITE_TOOLS = new Set(['create_project', 'rename_project', 'add_parts', 'update_part', 'update_parts', 'delete_parts', 'save_produit']);

// -----------------------------------------------------------------------------
// Erreurs
// -----------------------------------------------------------------------------
class ToolError extends Error {}

const SQL_ERRORS = {
  invalid_token: "Jeton invalide, révoqué ou expiré. Crée-en un nouveau dans MecaBench > Mon compte > Accès API.",
  read_only_token: "Ce jeton est en lecture seule. Crée un jeton avec la portée « modification » pour écrire.",
  not_found: "Projet introuvable (ou pas accessible avec ce compte).",
  forbidden: "Action refusée : droits insuffisants (lecteur dans cette équipe ?).",
  version_conflict: "Le projet a été modifié entre-temps.",
  invalid_data: "Données invalides.",
  data_too_large: "Le projet dépasse la taille maximale (4 Mo).",
  invalid_title: "Titre trop long (200 caractères max).",
};

function mapSqlError(e) {
  const msg = String((e && e.message) || e || '');
  for (const k of Object.keys(SQL_ERRORS)) if (msg.includes(k)) return { code: k, text: SQL_ERRORS[k] };
  return { code: 'error', text: msg };
}

// -----------------------------------------------------------------------------
// Accès base : appels RPC PostgREST avec la clé de service
// -----------------------------------------------------------------------------
function makeRpc(env, fetchImpl) {
  const f = fetchImpl || fetch;
  return async function rpc(fn, args) {
    const res = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      // clés « sb_secret_… » : en-tête apikey seul ; ancienne clé service_role (JWT) : aussi Authorization
      headers: Object.assign({ 'Content-Type': 'application/json', apikey: env.SERVICE_KEY }, String(env.SERVICE_KEY).startsWith('sb_') ? {} : { Authorization: `Bearer ${env.SERVICE_KEY}` }),
      body: JSON.stringify(args),
    });
    const text = await res.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
    if (!res.ok) {
      const m = mapSqlError(body && body.message ? body.message : text);
      const err = new Error(m.text);
      err.code = m.code;
      throw err;
    }
    return body;
  };
}

// -----------------------------------------------------------------------------
// Outils de manipulation des données d'un projet (purs, testables)
// -----------------------------------------------------------------------------
function str(v, max) {
  if (v === undefined || v === null) return '';
  const s = String(v).trim();
  return s.length > (max || MAX_FIELD) ? s.slice(0, max || MAX_FIELD) : s;
}

function numStr(v) {
  if (v === undefined || v === null || v === '') return '';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : '';
  const s = String(v).trim().replace(',', '.');
  return Number.isFinite(parseFloat(s)) ? s : '';
}

function maxNumericId(list, strip) {
  let m = 0;
  for (const x of list) {
    const n = parseInt(String(x.id || '').replace(strip || /^$/, ''), 10);
    if (!isNaN(n) && n > m) m = n;
  }
  return m;
}

function findGroup(data, name) {
  const key = str(name).toLowerCase();
  return data.dbGroups.find((g) => str(g.name).toLowerCase() === key && !g.parentId) || data.dbGroups.find((g) => str(g.name).toLowerCase() === key) || null;
}

// name : nom simple (« Vis ») ou chemin de sous-groupes séparés par « > » (« Limon > Limon simple > Sapin »).
// Chaque niveau est cherché parmi les enfants du niveau précédent et créé s'il manque.
function ensureGroup(data, name) {
  const parts = String(name).split('>').map((x) => str(x, 100)).filter(Boolean);
  if (parts.length <= 1) {
    let g = findGroup(data, name);
    if (!g) {
      g = { id: 'g' + (maxNumericId(data.dbGroups, /^g/) + 1), name: str(name, 100), collapsed: false, parentId: null };
      data.dbGroups.push(g);
    }
    return g;
  }
  if (parts.length > 6) throw new ToolError('Chemin de groupe trop profond (6 niveaux max).');
  let parent = null;
  for (const part of parts) {
    const key = part.toLowerCase();
    let g = data.dbGroups.find((x) => str(x.name).toLowerCase() === key && (x.parentId || null) === parent);
    if (!g) {
      g = { id: 'g' + (maxNumericId(data.dbGroups, /^g/) + 1), name: part, collapsed: false, parentId: parent };
      data.dbGroups.push(g);
    }
    parent = g.id;
  }
  return data.dbGroups.find((x) => x.id === parent);
}

function normalizeData(data) {
  const d = data && typeof data === 'object' ? data : {};
  for (const k of ['db', 'dbGroups', 'bruts', 'produits']) if (!Array.isArray(d[k])) d[k] = [];
  return d;
}

function addParts(data, parts, onDuplicate) {
  const added = [];
  const skipped = [];
  const byRef = new Map(data.db.map((p) => [str(p.reference).toLowerCase(), p]));
  let next = maxNumericId(data.db) + 1;
  for (const raw of parts || []) {
    const reference = str(raw.reference);
    const nom = str(raw.nom);
    if (!reference && !nom) { skipped.push({ reason: 'référence et nom vides' }); continue; }
    if (reference && onDuplicate !== 'add' && byRef.has(reference.toLowerCase())) {
      skipped.push({ reference, reason: 'référence déjà présente', part_id: byRef.get(reference.toLowerCase()).id });
      continue;
    }
    const part = { id: String(next++), nom, reference, prix: numStr(raw.prix), categorie: str(raw.categorie), matiere: str(raw.matiere), pm: numStr(raw.pm), va: numStr(raw.va) };
    if (str(raw.group)) part.groupId = ensureGroup(data, raw.group).id;
    if (raw.temp !== undefined) part.tempPrice = !!raw.temp;
    data.db.push(part);
    byRef.set(reference.toLowerCase(), part);
    added.push({ part_id: part.id, reference, nom });
  }
  return { added, skipped };
}

function updatePart(data, partId, fields) {
  const p = data.db.find((x) => String(x.id) === String(partId));
  if (!p) throw new ToolError(`Pièce introuvable : ${partId}`);
  const f = fields || {};
  for (const k of ['reference', 'nom', 'matiere', 'categorie']) if (k in f) p[k] = str(f[k]);
  for (const k of ['prix', 'pm', 'va']) if (k in f) p[k] = numStr(f[k]);
  if ('temp' in f) p.tempPrice = !!f.temp;
  else if ('prix' in f) p.tempPrice = null;
  if ('group' in f) {
    if (str(f.group)) p.groupId = ensureGroup(data, f.group).id; else delete p.groupId;
  }
  // les lignes de produits liées à la pièce reprennent sa référence et son nom
  let synced = 0;
  for (const pr of data.produits) for (const r of pr.rows || []) if (r.dbId === p.id) { r.nom = p.nom; r.reference = p.reference; synced++; }
  return { part_id: p.id, reference: p.reference, nom: p.nom, produit_rows_synced: synced };
}

function updateParts(data, updates) {
  if (!Array.isArray(updates) || !updates.length) throw new ToolError('updates est obligatoire (liste non vide).');
  if (updates.length > 500) throw new ToolError('500 modifications maximum par appel.');
  const missing = updates.filter((u) => !data.db.some((x) => String(x.id) === String(u && u.part_id))).map((u) => u && u.part_id);
  if (missing.length) throw new ToolError(`Pièce(s) introuvable(s) : ${missing.join(', ')}. Rien n'a été modifié.`);
  const updated = updates.map((u) => updatePart(data, u.part_id, u.fields));
  return { updated: updated.length, parts: updated.map((u) => ({ part_id: u.part_id, nom: u.nom })) };
}

function deleteParts(data, ids) {
  const wanted = new Set((ids || []).map(String));
  const used = new Map();
  for (const pr of data.produits) for (const r of pr.rows || []) if (r.dbId && wanted.has(String(r.dbId))) used.set(String(r.dbId), pr.title || pr.id);
  const deleted = [];
  const refused = [];
  const missing = [];
  for (const id of wanted) {
    const p = data.db.find((x) => String(x.id) === id);
    if (!p) missing.push(id);
    else if (used.has(id)) refused.push({ part_id: id, reference: p.reference, used_in_produit: used.get(id) });
    else deleted.push(id);
  }
  const del = new Set(deleted);
  data.db = data.db.filter((p) => !del.has(String(p.id)));
  return { deleted, refused, not_found: missing };
}

// arbre de blocs -> lignes plates, au format de l'appli :
//  - ligne racine (parent '') = pack, sachet (isSachet) ou pack spécial (special)
//  - ligne enfant = pièce (dbId), renvoi vers un bloc racine (packRefId) ou ligne libre
// Les ids sont attribués dans l'ordre (rang + 1), comme l'appli.
function treeToRows(tree, data, oldRows) {
  if (!Array.isArray(tree)) throw new ToolError("'tree' doit être une liste de blocs.");
  const rows = [];
  const unmatched = [];
  let count = 0;
  const partById = new Map(data.db.map((p) => [String(p.id), p]));
  const partByRef = new Map();
  for (const p of data.db) { const k = str(p.reference).toLowerCase(); if (k && !partByRef.has(k)) partByRef.set(k, p); }
  // couleur d'aperçu : reprise de l'ancien bloc de même type et même nom
  const oldColor = new Map();
  for (const r of oldRows || []) if (!str(r.parent) && r.previewColor) oldColor.set(blockKind(r) + '|' + str(r.nom).toLowerCase(), r.previewColor);

  // 1) blocs racines : ids et clés de renvoi
  const roots = [];
  const byKey = new Map();
  const byNom = new Map();
  let nextId = 1; // ordre de l'appli : chaque bloc suivi de ses lignes
  tree.forEach((n, i) => {
    if (!n || typeof n !== 'object') throw new ToolError(`Bloc ${i + 1} invalide.`);
    if (n.pack !== undefined || n.part_id !== undefined) throw new ToolError(`Bloc racine ${i + 1} : 'pack' et 'part_id' ne sont permis que dans les lignes d'un bloc.`);
    const kind = n.kind || 'pack';
    if (!['pack', 'sachet', 'special'].includes(kind)) throw new ToolError(`Bloc ${i + 1} : kind inconnu « ${n.kind} ».`);
    const nom = str(n.nom);
    if (!nom) throw new ToolError(`Bloc racine ${i + 1} : 'nom' est obligatoire.`);
    const id = String(nextId);
    nextId += 1 + (Array.isArray(n.children) ? n.children.length : 0);
    const key = str(n.key);
    if (key) {
      if (byKey.has(key.toLowerCase())) throw new ToolError(`Clé de bloc en double : « ${key} ».`);
      byKey.set(key.toLowerCase(), id);
    }
    const nk = nom.toLowerCase();
    byNom.set(nk, byNom.has(nk) ? null : id); // null = nom ambigu
    roots.push({ n, kind, nom, id });
  });
  if (roots.length > MAX_NODES) throw new ToolError(`Trop de lignes (max ${MAX_NODES}).`);
  count = roots.length;

  const resolvePack = (ref, where) => {
    const k = str(ref).toLowerCase();
    if (byKey.has(k)) return byKey.get(k);
    if (byNom.has(k)) {
      if (byNom.get(k) === null) throw new ToolError(`${where} : plusieurs blocs s'appellent « ${ref} », utilise 'key'.`);
      return byNom.get(k);
    }
    throw new ToolError(`${where} : bloc « ${ref} » introuvable (key ou nom d'un bloc racine).`);
  };

  // 2) lignes : chaque bloc racine suivi de ses lignes (les ids des racines sont connus d'avance,
  //    un renvoi peut donc viser un bloc placé plus loin)
  const rootRow = new Map();
  for (const { n, kind, nom, id } of roots) {
    const row = { id, nombre: numStr(n.quantity) || '1', reference: str(n.reference) || 'ref', nom, parent: '' };
    if (kind === 'sachet') row.isSachet = true;
    if (kind === 'special') row.special = true;
    if (numStr(n.va)) row.va = numStr(n.va);
    const color = oldColor.get(kind + '|' + nom.toLowerCase());
    if (color) row.previewColor = color;
    rootRow.set(id, row);
  }
  const refs = new Map(); // id racine -> ids racines référencés
  for (const { n, nom, id } of roots) {
    rows.push(rootRow.get(id));
    refs.set(id, []);
    (n.children || []).forEach((c, j) => {
      const where = `« ${nom} », ligne ${j + 1}`;
      if (++count > MAX_NODES) throw new ToolError(`Trop de lignes (max ${MAX_NODES}).`);
      if (!c || typeof c !== 'object') throw new ToolError(`${where} invalide.`);
      if (Array.isArray(c.children) && c.children.length) throw new ToolError(`${where} : une ligne ne peut pas avoir d'enfants. Crée un bloc racine et renvoie-y avec 'pack'.`);
      if (c.kind !== undefined || c.key !== undefined) throw new ToolError(`${where} : 'kind' et 'key' sont réservés aux blocs racines.`);
      const rowId = String(rows.length + 1);
      const qty = numStr(c.quantity) || '1';
      if (c.pack !== undefined) {
        const target = resolvePack(c.pack, where);
        const t = rootRow.get(target);
        if (t.special) throw new ToolError(`${where} : un pack spécial ne peut pas être inclus dans un autre bloc.`);
        if (target === id) throw new ToolError(`${where} : un bloc ne peut pas se contenir lui-même.`);
        rows.push({ id: rowId, nombre: qty, reference: t.reference, nom: t.nom, parent: id, packRefId: target });
        refs.get(id).push(target);
        return;
      }
      let part = null;
      if (c.part_id !== undefined && c.part_id !== null && c.part_id !== '') {
        part = partById.get(String(c.part_id));
        if (!part) throw new ToolError(`${where} : pièce introuvable (part_id ${c.part_id}).`);
      } else if (str(c.reference)) {
        part = partByRef.get(str(c.reference).toLowerCase()) || null;
      }
      const row = { id: rowId, nombre: qty, reference: part ? part.reference : str(c.reference) || 'Référence', nom: part ? part.nom : str(c.nom) || 'Nom', parent: id };
      if (part) row.dbId = part.id;
      else unmatched.push(`${nom} > ${str(c.reference) || str(c.nom)}`);
      rows.push(row);
    });
  }

  // 3) pas de boucle entre blocs (A contient B qui contient A)
  const state = new Map();
  const visit = (id, path) => {
    if (state.get(id) === 2) return;
    if (state.get(id) === 1) throw new ToolError(`Boucle entre blocs : ${path.concat(id).map((x) => rootRow.get(x).nom).join(' > ')}.`);
    state.set(id, 1);
    for (const t of refs.get(id) || []) visit(t, path.concat(id));
    state.set(id, 2);
  };
  for (const { id } of roots) visit(id, []);
  return { rows, unmatched };
}

function blockKind(r) {
  return r.special ? 'special' : r.isSachet ? 'sachet' : 'pack';
}

// lignes plates -> arbre de blocs (même format que l'entrée de save_produit)
function rowsToTree(rows) {
  const list = rows || [];
  const kids = new Map();
  for (const r of list) {
    const k = str(r.parent);
    if (!k) continue;
    if (!kids.has(k)) kids.set(k, []);
    kids.get(k).push(r);
  }
  const line = (r) => {
    const n = { reference: r.reference, nom: r.nom, quantity: r.nombre };
    if (r.packRefId) {
      n.pack = 'r' + String(r.packRefId).trim();
    } else if (r.dbId) n.part_id = r.dbId;
    const sub = kids.get(String(r.id).trim());
    if (sub && sub.length) n.children = sub.map(line); // ancien format imbriqué
    return n;
  };
  return list.filter((r) => !str(r.parent)).map((r) => {
    const n = { kind: blockKind(r), key: 'r' + String(r.id).trim(), reference: r.reference, nom: r.nom, quantity: r.nombre };
    if (r.va) n.va = r.va;
    const sub = kids.get(String(r.id).trim());
    if (sub && sub.length) n.children = sub.map(line);
    return n;
  });
}

function saveProduit(data, args) {
  let produit = args.produit_id ? data.produits.find((p) => String(p.id) === String(args.produit_id)) : null;
  if (args.produit_id && !produit) throw new ToolError(`Produit introuvable : ${args.produit_id}`);
  if (!produit) {
    if (!Array.isArray(args.tree)) throw new ToolError("Pour créer un produit, fournis 'tree' (liste de packs).");
    produit = { id: 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7), title: '', rows: [], notes: '', updatedAt: 0 };
    data.produits.push(produit);
  }
  let unmatched = [];
  if (args.title !== undefined) produit.title = str(args.title, 200);
  if (args.notes !== undefined) produit.notes = String(args.notes).slice(0, 20000);
  if (Array.isArray(args.tree)) {
    const r = treeToRows(args.tree, data, produit.rows);
    produit.rows = r.rows;
    unmatched = r.unmatched;
  }
  produit.updatedAt = Date.now();
  return { produit_id: produit.id, title: produit.title, rows: produit.rows.length, lignes_libres: unmatched };
}

function describeProject(g, include) {
  const data = normalizeData(g.data);
  const inc = new Set(include && include.length ? include : ['parts', 'groups', 'produits']);
  const out = {
    id: g.id, title: g.title, role: g.role, team: g.team_name || null, version: g.version, updated_at: g.updated_at,
    counts: { parts: data.db.length, groups: data.dbGroups.length, bruts: data.bruts.length, produits: data.produits.length },
  };
  if (inc.has('raw')) { out.data = data; return out; }
  if (inc.has('groups')) out.groups = data.dbGroups.map((x) => ({ id: x.id, name: x.name, parentId: x.parentId || null }));
  if (inc.has('parts')) out.parts = data.db.map((p) => ({ part_id: p.id, reference: p.reference, nom: p.nom, prix: p.prix, matiere: p.matiere || '', categorie: p.categorie || '', group: p.groupId || null, temp: !!p.tempPrice }));
  if (inc.has('bruts')) out.bruts = data.bruts.map((b) => ({ id: b.id, reference: b.reference, nom: b.nom, prix: b.prix }));
  if (inc.has('produits')) out.produits = data.produits.map((p) => ({ produit_id: p.id, title: p.title, notes: p.notes || '', rows: (p.rows || []).length, tree: rowsToTree(p.rows) }));
  return out;
}

// -----------------------------------------------------------------------------
// Exécution des outils
// -----------------------------------------------------------------------------
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function needUuid(v, name) {
  if (typeof v !== 'string' || !UUID_RE.test(v)) throw new ToolError(`${name} doit être un identifiant uuid (voir list_projects).`);
  return v;
}

// lecture -> modification -> écriture avec contrôle de version ; on réessaie si quelqu'un d'autre a écrit entre-temps
async function mutateProject(rpc, token, projectId, mutate) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const g = await rpc('api_get_projet', { p_token: token, p_id: projectId });
    if (g.role === 'viewer') throw new ToolError("Lecture seule : tu es lecteur dans cette équipe, tu ne peux pas modifier ce projet.");
    const data = normalizeData(JSON.parse(JSON.stringify(g.data || {})));
    const result = mutate(data, g) || {};
    const titleOnly = result.__title !== undefined; // renommage : on n'envoie pas les données
    const newTitle = titleOnly ? result.__title : null;
    delete result.__title;
    try {
      const u = await rpc('api_update_projet', { p_token: token, p_id: projectId, p_version: g.version, p_title: newTitle, p_data: titleOnly ? null : data });
      return Object.assign({ project_id: projectId, version: u.version }, result);
    } catch (e) {
      if (e.code === 'version_conflict' && attempt < 4) continue;
      if (e.code === 'version_conflict') throw new ToolError("Le projet est modifié en continu par quelqu'un d'autre : réessaie dans un instant.");
      throw e;
    }
  }
}

async function callTool(rpc, token, name, args) {
  args = args || {};
  switch (name) {
    case 'list_projects':
      return await rpc('api_list_projets', { p_token: token });
    case 'get_project': {
      const g = await rpc('api_get_projet', { p_token: token, p_id: needUuid(args.project_id, 'project_id') });
      return describeProject(g, args.include);
    }
    case 'create_project': {
      const title = str(args.title, 200);
      if (!title) throw new ToolError('title est obligatoire.');
      const team = args.team_id ? needUuid(args.team_id, 'team_id') : null;
      const r = await rpc('api_create_projet', { p_token: token, p_title: title, p_team: team, p_data: {} });
      return { project_id: r.id, version: r.version, title };
    }
    case 'rename_project': {
      const title = str(args.title, 200);
      if (!title) throw new ToolError('title est obligatoire.');
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), () => ({ __title: title, title }));
    }
    case 'add_parts': {
      if (!Array.isArray(args.parts) || !args.parts.length) throw new ToolError('parts est obligatoire (liste non vide).');
      if (args.parts.length > 500) throw new ToolError('500 pièces maximum par appel.');
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), (data) => addParts(data, args.parts, args.on_duplicate_reference));
    }
    case 'update_part':
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), (data) => updatePart(data, args.part_id, args.fields));
    case 'update_parts':
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), (data) => updateParts(data, args.updates));
    case 'delete_parts': {
      if (!Array.isArray(args.part_ids) || !args.part_ids.length) throw new ToolError('part_ids est obligatoire.');
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), (data) => deleteParts(data, args.part_ids));
    }
    case 'save_produit':
      return await mutateProject(rpc, token, needUuid(args.project_id, 'project_id'), (data) => saveProduit(data, args));
    default:
      throw new ToolError(`Outil inconnu : ${name}`);
  }
}

function toolResult(obj, isError) {
  let text = typeof obj === 'string' ? obj : JSON.stringify(obj, null, 1);
  if (text.length > MAX_OUTPUT_CHARS) text = text.slice(0, MAX_OUTPUT_CHARS) + '\n…(sortie tronquée ; demande une section plus précise avec include)';
  return { content: [{ type: 'text', text }], isError: !!isError };
}

// -----------------------------------------------------------------------------
// Protocole MCP (JSON-RPC 2.0 sur HTTP, réponses JSON)
// -----------------------------------------------------------------------------
async function handleRpcMessage(msg, ctx) {
  const id = msg && msg.id !== undefined ? msg.id : null;
  const isNotification = !msg || msg.id === undefined;
  const ok = (result) => ({ jsonrpc: '2.0', id, result });
  const fail = (code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return fail(-32600, 'Invalid Request');
  if (isNotification) return null;

  switch (msg.method) {
    case 'initialize': {
      // on vérifie le jeton dès la connexion pour que l'erreur soit visible tout de suite
      try { await ctx.rpc('api_list_projets', { p_token: ctx.token }); } catch (e) { return fail(-32001, e.message); }
      const wanted = msg.params && msg.params.protocolVersion;
      return ok({
        protocolVersion: SUPPORTED_PROTOCOLS.includes(wanted) ? wanted : SUPPORTED_PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case 'ping':
      return ok({});
    case 'tools/list':
      return ok({ tools: TOOLS });
    case 'tools/call': {
      const name = msg.params && msg.params.name;
      if (!TOOLS.some((t) => t.name === name)) return fail(-32602, `Unknown tool: ${name}`);
      try {
        const out = await callTool(ctx.rpc, ctx.token, name, msg.params.arguments);
        return ok(toolResult(out, false));
      } catch (e) {
        return ok(toolResult(e instanceof ToolError || e.code ? e.message : 'Erreur interne : ' + e.message, true));
      }
    }
    default:
      return fail(-32601, `Method not found: ${msg.method}`);
  }
}

function extractToken(req) {
  const auth = req.headers.get('authorization') || '';
  const m = /^Bearer\s+(mbk_[0-9a-f]{64})$/i.exec(auth.trim());
  if (m) return m[1];
  const seg = new URL(req.url).pathname.split('/').filter(Boolean).pop() || '';
  return /^mbk_[0-9a-f]{64}$/.test(seg) ? seg : null;
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, mcp-protocol-version, mcp-session-id, accept',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(status, body, extra) {
  return new Response(body === null ? null : JSON.stringify(body), { status, headers: Object.assign({ 'Content-Type': 'application/json' }, CORS, extra || {}) });
}

async function handleRequest(req, env, fetchImpl) {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'Use POST (MCP over HTTP).' }, { Allow: 'POST, OPTIONS' });
  const token = extractToken(req);
  if (!token) return json(401, { error: 'Jeton MecaBench manquant (Authorization: Bearer mbk_… ou jeton dans l\'URL).' });
  let body;
  try { body = await req.json(); } catch (_) { return json(400, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); }
  const ctx = { token, rpc: makeRpc(env, fetchImpl) };
  if (Array.isArray(body)) {
    const out = (await Promise.all(body.map((m) => handleRpcMessage(m, ctx)))).filter((x) => x !== null);
    return out.length ? json(200, out) : json(202, null);
  }
  const res = await handleRpcMessage(body, ctx);
  return res === null ? json(202, null) : json(200, res);
}

// Point d'entrée Supabase (Deno). Ignoré quand le fichier est importé par les tests Node.
if (typeof Deno !== 'undefined' && Deno.serve) {
  Deno.serve((req) => handleRequest(req, { SUPABASE_URL: Deno.env.get('SUPABASE_URL'), SERVICE_KEY: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') }));
}

export { handleRequest, handleRpcMessage, callTool, addParts, updatePart, updateParts, deleteParts, saveProduit, treeToRows, rowsToTree, mutateProject, TOOLS, WRITE_TOOLS };
