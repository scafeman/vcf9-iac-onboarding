import fs from 'fs';

/**
 * Parse a vault-injected secret file containing key=value pairs (one per line).
 * Returns a Record mapping keys to values.
 */
export function parseVaultFile(path: string): Record<string, string> {
  const content = fs.readFileSync(path, 'utf-8');
  const result: Record<string, string> = {};
  for (const line of content.split('\n')) {
    const [key, ...rest] = line.split('=');
    if (key && rest.length > 0) {
      result[key.trim()] = rest.join('=').trim();
    }
  }
  return result;
}
