// Shared with the browser, so no Node imports here.
export function markdownPathFor(route: string): string {
  return route === '/' ? '/index.md' : `${route.replace(/\/+$/, '')}.md`;
}
