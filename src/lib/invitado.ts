// src/lib/invitado.ts
//
// Punto único desde donde la invitación habla con la base de datos.
//
// ⚠️ NO importar `./supabase` de forma estática aquí arriba. La librería pesa
// 220 KB (58 KB comprimida) y este módulo lo cargan varios componentes: con
// import estático, TODA visita se bajaría ese peso aunque el link no traiga
// código. Con import() dinámico solo se descarga cuando hace falta.

/** Lo que tiene contratado esta boda. Lo decide el panel, no la invitación. */
export type Funciones = {
  confirmacion?: boolean;
  mesa?: boolean;
  acompanantes?: boolean;
};

export type Invitado = {
  nombre: string;
  pases: number;
  confirmado: boolean | null;
  asisten: number | null;
  acompanantes: string[];
  mesa: number | null;
  funciones: Funciones;
};

/** El código corto que viaja en el link: ...?i=k7m2p */
export function codigoDelLink(): string | null {
  if (typeof window === "undefined") return null;
  const codigo = new URLSearchParams(window.location.search).get("i");
  return codigo && codigo.trim() ? codigo.trim() : null;
}

/**
 * En qué quedó la búsqueda del código del link:
 *
 *   sin-codigo     el link no trae ?i=, es la invitación genérica
 *   ok             se encontró al invitado
 *   no-existe      el código no está en la base: lo borraron
 *   sin-respuesta  la base no contestó (pausada, sin internet)
 *
 * La diferencia entre los dos últimos importa: a un invitado borrado hay
 * que decírselo, pero si lo que falla es la conexión la invitación tiene
 * que seguir mostrándose como si nada.
 */
export type EstadoLink = "sin-codigo" | "ok" | "no-existe" | "sin-respuesta";

let estado: EstadoLink = "sin-codigo";

/** Espera a que termine la búsqueda y dice en qué quedó. */
export async function estadoDelLink(): Promise<EstadoLink> {
  await datosInvitado();
  return estado;
}

// Varios componentes piden los mismos datos. Se guarda la promesa para que la
// consulta salga UNA sola vez por visita, la pidan dos componentes o cinco.
let pedido: Promise<Invitado | null> | null = null;

/**
 * Datos del invitado del link, o null si no hay código, si la base no
 * responde o si el código no existe.
 *
 * Nunca lanza: si Supabase está caído o el proyecto pausado, la invitación
 * sigue mostrando los valores por defecto y el invitado ni se entera.
 */
export function datosInvitado(): Promise<Invitado | null> {
  if (pedido) return pedido;

  const codigo = codigoDelLink();
  if (!codigo) {
    pedido = Promise.resolve(null);
    return pedido;
  }

  pedido = import("./supabase")
    .then(({ supabase, configurado }) => {
      if (!configurado || !supabase) {
        estado = "sin-respuesta";
        return null;
      }
      return supabase
        .rpc("buscar_invitado", { codigo_buscado: codigo })
        .then(({ data, error }: { data: Invitado[] | null; error: unknown }) => {
          if (error) {
            estado = "sin-respuesta";
            return null;
          }
          if (!data || !data.length) {
            // La base contestó y no hay nadie con ese código: lo borraron.
            estado = "no-existe";
            return null;
          }
          estado = "ok";
          return data[0];
        });
    })
    .catch(() => {
      estado = "sin-respuesta";
      return null;
    });

  return pedido;
}

// ═══════════════════════════════════════════════════════════════════════════
//  MANTENERSE AL DÍA
//
//  Si los novios corrigen los pases o borran a alguien mientras el invitado
//  tiene la invitación abierta, conviene que la pantalla se entere.
//
//  No se usa la conexión en vivo de Supabase a propósito: el invitado es
//  anónimo y la base no le manda nada, que es justo lo que impide que un
//  curioso se quede escuchando los cambios de toda la lista. Así que se
//  vuelve a preguntar cada tanto, y sobre todo al volver a la pestaña, que
//  es cuando de verdad pasa: el invitado deja la página abierta, los novios
//  corrigen, el invitado vuelve.
// ═══════════════════════════════════════════════════════════════════════════

type Escucha = (invitado: Invitado | null, estado: EstadoLink) => void;

const escuchas: Escucha[] = [];
let vigilando = false;
let ultimo = "";

/** Avisa cada vez que cambian los datos del invitado del link. */
export function alCambiarInvitado(fn: Escucha): void {
  escuchas.push(fn);
  vigilar();
}

async function revisar(): Promise<void> {
  // Con la pestaña en segundo plano no se consulta: el invitado no está
  // mirando y no tiene sentido gastarle datos.
  if (typeof document !== "undefined" && document.hidden) return;
  if (!codigoDelLink()) return;

  pedido = null;                       // se fuerza una consulta nueva
  const invitado = await datosInvitado();

  const ahora = JSON.stringify([invitado, estado]);
  if (ahora === ultimo) return;        // nada cambió, nadie se entera
  ultimo = ahora;

  for (const fn of escuchas) {
    try {
      fn(invitado, estado);
    } catch {
      /* que un componente falle no puede dejar sin avisar a los demás */
    }
  }
}

function vigilar(): void {
  if (vigilando || typeof window === "undefined") return;
  if (!codigoDelLink()) return;        // sin código no hay nada que vigilar
  vigilando = true;

  datosInvitado().then((inv) => {
    ultimo = JSON.stringify([inv, estado]);
  });

  // Al volver a la pestaña, de inmediato
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) revisar();
  });
  window.addEventListener("focus", revisar);

  // Y cada 10 segundos mientras se esté mirando. La consulta devuelve una
  // fila mínima, así que a esta frecuencia sigue siendo insignificante, y
  // para quien está mirando la pantalla 10 segundos se sienten inmediatos.
  setInterval(revisar, 10000);
}

/**
 * Guarda la respuesta del invitado.
 *
 *   asiste = true   → confirma; `cantidad` se recorta al máximo de sus pases
 *   asiste = false  → avisa que no viene
 *
 * Devuelve la fila actualizada, o null si falló. La base solo deja tocar la
 * fila de ESE código y solo las columnas de confirmación (ver la función
 * confirmar_asistencia en supabase/schema.sql). Si la boda no tiene la
 * función `confirmacion` contratada, la base ignora el pedido.
 */
export async function confirmarAsistencia(
  asiste: boolean,
  cantidad?: number,
  acompanantes?: string[],
): Promise<Invitado | null> {
  const codigo = codigoDelLink();
  if (!codigo) return null;

  try {
    const { supabase, configurado } = await import("./supabase");
    if (!configurado || !supabase) return null;

    const { data, error } = await supabase.rpc("confirmar_asistencia", {
      codigo_buscado: codigo,
      asiste,
      cantidad: cantidad ?? null,
      acompanantes_nuevos: acompanantes ?? null,
    });

    if (error || !data || !data.length) return null;

    const fila = data[0] as Invitado;
    pedido = Promise.resolve(fila); // el caché queda al día
    return fila;
  } catch {
    return null;
  }
}
