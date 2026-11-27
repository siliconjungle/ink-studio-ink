import { callOwned, compiledValues, JsonCodec } from '../build/pixel_document.mjs';

const codec = new JsonCodec(compiledValues.open_pixel_document.params[0]);
const utf8 = new TextEncoder();

async function revision(document) {
  const bytes = await crypto.subtle.digest('SHA-256', utf8.encode(JSON.stringify(document)));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('');
}

export async function openPixelDocument(source) {
  const input = typeof source === 'string' ? JSON.parse(source) : source;
  const opened = callOwned('open_pixel_document', [codec.fromJS(input)]);
  if (Object.hasOwn(opened, 'Err')) throw new Error(opened.Err);
  const document = codec.toJS(opened.Ok.document);
  const [current, legacy] = await Promise.all([
    revision(document),
    opened.Ok.legacy ? revision(input) : null,
  ]);
  return { document, revision: current, legacyRevision: legacy };
}
