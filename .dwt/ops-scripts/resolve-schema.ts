#!/usr/bin/env bun
/**
 * resolve-schema.ts
 * Dereferences $ref/$defs in a JSON Schema file and outputs a flat schema
 * compatible with Claude CLI's --json-schema parameter.
 *
 * Usage: bun run resolve-schema.ts <schema-file.json>
 * Output: Flat JSON Schema string to stdout (compact, no $ref/$defs/$schema/$comment)
 */

const { console, process } = globalThis;

const schemaPath = process.argv[2];

if (!schemaPath) {
  console.error('Usage: bun run resolve-schema.ts <schema-file.json>');
  process.exit(1);
}

const file = Bun.file(schemaPath);
const schema = await file.json();
const defs: Record<string, unknown> = (schema as Record<string, unknown>)['$defs'] as Record<string, unknown> ?? {};

type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };

function deref(node: unknown): JsonValue {
  if (node === null || node === undefined) return node as JsonValue;
  if (typeof node !== 'object') return node as JsonValue;
  if (Array.isArray(node)) return node.map(deref);

  const obj = node as Record<string, unknown>;

  // Resolve $ref
  if (obj['$ref'] && typeof obj['$ref'] === 'string') {
    const refPath = obj['$ref'] as string;
    const key = refPath.split('/').pop()!;
    if (!(key in defs)) {
      throw new Error(`Unresolved $ref: ${refPath}`);
    }
    return deref(defs[key]);
  }

  // Recurse into object, stripping meta keys
  const result: Record<string, JsonValue> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === '$defs' || k === '$schema' || k === '$comment') continue;
    result[k] = deref(v);
  }
  return result;
}

console.log(JSON.stringify(deref(schema)));
