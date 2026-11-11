import Bonjour, { type Service, type ServiceConfig } from "bonjour-service";

/**
 * mDNS is the zero-typing path: a phone on the same network browses
 * `_syndro._tcp` and learns host + port without scanning a QR code.
 *
 * The TXT record deliberately carries no token. Discovery only tells a client
 * *where* a share lives; the 8-character code is still required to use it, so
 * anyone who can see the multicast traffic learns nothing usable.
 */
export const SERVICE_TYPE = "syndro";
export const PROTOCOL_VERSION = "1";

export interface DiscoveryInfo {
  /** Stable per-install identifier, used to recognise a device again. */
  id: string;
  name: string;
  port: number;
}

export interface Discovery {
  /** The advertised instance name, which may have been de-duplicated by mDNS. */
  readonly serviceName: string;
  stop(): void;
}

export function serviceConfig(info: DiscoveryInfo): ServiceConfig {
  return {
    name: info.name,
    type: SERVICE_TYPE,
    protocol: "tcp",
    port: info.port,
    txt: {
      id: info.id,
      name: info.name,
      ver: PROTOCOL_VERSION,
    },
  };
}

export function advertise(info: DiscoveryInfo): Discovery {
  const bonjour = new Bonjour({}, (error: unknown) => {
    console.error("Syndro mDNS error:", error);
  });
  let service: Service | null = null;
  let stopped = false;

  try {
    service = bonjour.publish(serviceConfig(info));
  } catch (error) {
    console.error("Syndro could not advertise over mDNS:", error);
    try {
      bonjour.destroy();
    } catch {
      // Nothing else to clean up.
    }
  }

  return {
    serviceName: service?.name ?? info.name,
    stop() {
      if (stopped) return;
      stopped = true;
      try {
        service?.stop(() => bonjour.destroy());
        if (!service) bonjour.destroy();
      } catch (error) {
        console.error("Syndro could not stop mDNS advertisement:", error);
      }
    },
  };
}
