/**
 * Shared CORS headers for all edge functions.
 * Allows requests from the Expo app and web origins.
 */

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-webhook-secret',
  'Access-Control-Max-Age': '86400',
};

/**
 * Returns a preflight response for OPTIONS requests.
 */
export function handleCors(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders, status: 200 });
  }
  return null;
}

/**
 * Wraps a JSON body with CORS headers and proper content type.
 */
export function jsonResponse(
  body: Record<string, unknown> | unknown[],
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

/**
 * Returns a standardized error response with CORS headers.
 */
export function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ error: message }, status);
}
