import { decompress as zstdDecompress } from "https://cdn.jsdelivr.net/npm/fzstd@0.1.1/+esm";
import jsUntar from "https://cdn.jsdelivr.net/npm/js-untar@2.0.0/+esm";

let db = null;
let db_name = "stk_db";
let store_name = "stk_store";
let idbfs_mount = null;
let data_version = 2;  // Bumped: zstd format + split archives

let start_button = document.getElementById("start_button");
let status_text = document.getElementById("status_text");
let info_container = document.getElementById("info_container");
let quality_select = document.getElementById("quality_select");

let syncing_fs = false;
let config = {};

function load_db() {
  if (db) return db;
  return new Promise((resolve, reject) => {
    let request = indexedDB.open(db_name, 1);
    request.onerror = (event) => {
      reject(event);
    };
    request.onsuccess = (event) => {
      db = event.target.result;
      resolve(db);
    };
    request.onupgradeneeded = (event) => {
      let db = event.target.result;
      db.createObjectStore(store_name);
    };
  });
}

function request_async(request) {
  return new Promise((resolve, reject) => {
    request.onerror = (event) => {
      reject(event);
    };
    request.onsuccess = () => {
      resolve(request.result);
    };
  });
}

async function delete_db() {
  if (db) {
    db.close();
    db = null;
  }
  await request_async(indexedDB.deleteDatabase(db_name));
}

async function load_store() {
  await load_db();
  let transaction = db.transaction(store_name, "readwrite");
  let store = transaction.objectStore(store_name);
  return store;
}

async function check_db(key) {
  let store = await load_store();
  return await request_async(store.count(key));
}

async function read_db(key) {
  let store = await load_store();
  return await request_async(store.get(key));
}

async function write_db(key, data) {
  let store = await load_store();
  return await request_async(store.put(data, key));
}

async function read_db_chunks(key) {
  let {size, chunk_count} = await read_db(key);
  let offset = 0;
  let array = new Uint8Array(size);

  for (let i = 0; i < chunk_count; i++) {
    let chunk_array = await read_db(key + "." + i);
    array.set(chunk_array, offset);
    offset += chunk_array.length;
  }

  return array;
}

async function write_db_chunks(key, data) {
  let size = data.length;
  let chunk_size = 20_000_000;
  let chunk_count = Math.ceil(size / chunk_size);

  let offset = 0;
  for (let i = 0; i < chunk_count; i++) {
    let chunk_array = data.slice(offset, offset + chunk_size);
    await write_db(key + "." + i, chunk_array);
    offset += chunk_size;
  }

  await write_db(key, {size, chunk_count});
}

async function download_chunks(url) {
  let path = url.split("/");
  let filename = path.pop();
  let base_url = path.join("/");

  status_text.textContent = `Downloading manifest for ${filename}...`;
  let r1 = await fetch(url + ".manifest");
  if (!r1.ok) {
    throw new Error(`Asset pack "${filename}" not available (HTTP ${r1.status}). Try selecting "Low" quality.`);
  }
  let manifest = (await r1.text()).split("\n");
  let size = parseInt(manifest.shift());
  if (isNaN(size) || size <= 0) {
    throw new Error(`Invalid manifest for "${filename}".`);
  }
  manifest.pop();

  let offset = 0;
  let chunk = null;
  let array = new Uint8Array(size);
  let chunk_count = manifest.length;
  let current_chunk = 1;

  while (chunk = manifest.shift()) {
    let mb_progress = Math.floor(offset / (1024 ** 2))
    let mb_total = Math.floor(size / (1024 ** 2))
    status_text.textContent = `Downloading ${filename}... (chunk ${current_chunk}/${chunk_count}, ${mb_progress}/${mb_total}MiB)`;

    let r2 = await fetch(base_url + "/" + chunk);
    let buffer = await r2.arrayBuffer();
    let chunk_array = new Uint8Array(buffer);
    array.set(chunk_array, offset);
    offset += chunk_array.length;
    current_chunk++;
  }

  return array.buffer;
}

async function extract_tar(url, fs_path, use_cache = false) {
  let decompressed;
  if (!use_cache || !await check_db(url)) {
    let filename = url.split("/").pop();
    let compressed = await download_chunks(url);
    status_text.textContent = `Decompressing ${filename}...`;
    decompressed = zstdDecompress(new Uint8Array(compressed));
    compressed = null;
    if (use_cache) {
      status_text.textContent = `Saving ${filename} to the cache...`;
      await write_db_chunks(url, decompressed);
    }
  }
  else {
    decompressed = await read_db_chunks(url);
  }

  let files = await jsUntar(decompressed.buffer);
  for (let file of files) {
    let relative_path = file.name.substring(1);
    let out_path = fs_path + relative_path;
    if (out_path.endsWith("/")) {
      try {
        FS.mkdir(out_path);
      }
      catch {}
    }
    else {
      let array = new Uint8Array(file.buffer);
      FS.writeFile(out_path, array);
      file.buffer = null;
    }
  }
}

async function load_data() {
  if (!await check_db("/version") || !(await read_db("/version") == data_version)) {
    await delete_db();
    await write_db("/version", data_version);
  }

  let quality = quality_select.value;

  // Phase 1: Core assets (textures, music, sfx, models, library, karts)
  await extract_tar(`game/data_${quality}_core.tar.zst`, "/data", true);

  // Phase 2: Track data (all track directories)
  await extract_tar(`game/data_${quality}_tracks.tar.zst`, "/data", true);
}

async function load_idbfs() {
  idbfs_mount = FS.mount(IDBFS, {}, "/home").mount;
  await sync_idbfs(true);
}

function sync_idbfs(populate = false) {
  if (syncing_fs) return;
  syncing_fs = true;
  return new Promise((resolve, reject) => {
    idbfs_mount.type.syncfs(idbfs_mount, populate, (err) => {
      syncing_fs = false;
      if (err) reject(err);
      else resolve();
    });
  })
}

function wait_for_frame() {
  return new Promise((resolve) => {requestAnimationFrame(resolve)});
}

async function main() {
  await load_idbfs();

  start_button.onclick = start_game;
  start_button.disabled = false;
  status_text.innerText = "";
}

async function start_game() {
  status_text.textContent = "Loading game files...";
  start_button.disabled = true;
  try {
    await load_data();
  } catch (e) {
    status_text.textContent = e.message;
    start_button.disabled = false;
    return;
  }
  await wait_for_frame();
  status_text.textContent = "Launching game (this may take 30-60s, the tab will freeze)...";

  await wait_for_frame();
  // Hide the info overlay before calling main — callMain() will block the
  // main thread during STK initialization, and emscripten_set_main_loop()
  // with simulate_infinite_loop=1 throws to unwind (code after callMain
  // may not execute).
  info_container.style.zIndex = 0;
  info_container.style.display = "none";

  try {
    callMain();
  } catch (e) {
    // emscripten_set_main_loop with simulate_infinite_loop=1 throws
    // to exit main(). This is expected behavior, not an error.
    if (e !== "unwind") throw e;
  }
  sync_idbfs();

  console.warn("Warning: Opening devtools may harm the game's performance.");
}

Module["canvas"] = document.getElementById("canvas")
globalThis.main = main;
globalThis.sync_idbfs = sync_idbfs;
globalThis.load_idbfs = load_idbfs;

let poll_runtime_interval = setInterval(() => {
  if (globalThis.ready) {
    main();
    clearInterval(poll_runtime_interval);
  }
}, 100);
