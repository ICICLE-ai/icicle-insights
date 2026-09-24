// A client-rendered single-page app. Vapor serves the static `index.html` fallback for every route,
// so there is no server to render on and nothing worth prerendering: every screen is data.
export const ssr = false;
export const prerender = false;
export const trailingSlash = 'never';
