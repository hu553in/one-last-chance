import * as z from 'zod/mini';

const publicIPv4Response = z.object({ ip: z.ipv4() });
const countryResponse = z.object({
  ip: z.ipv4(),
  country: z.string().check(z.regex(/^[A-Z]{2}$/)),
});

export type PublicIP = {
  address: string;
  country: string;
};

export function parsePublicIPv4Response(value: unknown): string {
  return publicIPv4Response.parse(value).ip;
}

export function parseIPCountryResponse(value: unknown, address: string): string {
  const response = countryResponse.parse(value);
  if (response.ip !== address) {
    throw new Error('IP country service returned a different IP address.');
  }
  return response.country;
}
