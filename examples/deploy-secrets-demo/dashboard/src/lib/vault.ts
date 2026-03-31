import fs from 'fs';

/**
 * Parse a vault-injected secret file.
 * Supports two formats:
 * 1. key=value per line (custom template)
 * 2. data: map[key1:value1 key2:value2] (default vault "map" template)
 * Returns a Record mapping keys to values.
 */
export function parseVaultFile(path: string): Record<string, string> {
  const content = fs.readFileSync(path, 'utf-8');
  const result: Record<string, string> = {};

  // Try to parse the default vault "map" template format: data: map[key1:value1 key2:value2]
  const mapMatch = content.match(/data:\s*map\[([^\]]+)\]/);
  if (mapMatch) {
    const mapContent = mapMatch[1];
    // Split on spaces, but handle values that might contain colons
    // Format: key1:value1 key2:value2
    const pairs = mapContent.split(/\s+/);
    for (const pair of pairs) {
      const colonIdx = pair.indexOf(':');
      if (colonIdx > 0) {
        const key = pair.substring(0, colonIdx);
        const value = pair.substring(colonIdx + 1);
        result[key] = value;
      }
    }
    return result;
  }

  // Fall back to key=value per line format
  for (const line of content.split('\n')) {
    const [key, ...rest] = line.split('=');
    if (key && rest.length > 0) {
      result[key.trim()] = rest.join('=').trim();
    }
  }
  return result;
}
