// src/lib/supabase.ts
// Cliente de Supabase para el navegador.
//
// La clave es pública a propósito: viaja al navegador de cada invitado.
// Lo que impide que alguien se descargue la lista completa son las
// reglas RLS definidas en supabase/schema.sql

import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.PUBLIC_SUPABASE_URL;
const key = import.meta.env.PUBLIC_SUPABASE_KEY;

/**
 * Si faltan las variables de entorno, createClient lanza al cargar el módulo
 * y se lleva por delante todo el script: la página se queda colgada sin decir
 * por qué. Mejor avisar y que quien use el cliente decida qué hacer.
 */
export const configurado = Boolean(url && key);

export const supabase = configurado
  ? createClient(url, key, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
      },
    })
  : null;

/**
 * Código corto que viaja en el link: ...?i=k7m2p
 * Sin vocales ni caracteres que se confundan (0/O, 1/l/I),
 * para que se pueda dictar por teléfono sin errores.
 */
export function generarCodigo(largo = 5): string {
  const alfabeto = "23456789bcdfghjkmnpqrstvwxyz";
  let codigo = "";
  const valores = new Uint32Array(largo);
  crypto.getRandomValues(valores);
  for (let i = 0; i < largo; i++) {
    codigo += alfabeto[valores[i] % alfabeto.length];
  }
  return codigo;
}

/** El link personalizado de un invitado */
export function linkInvitado(codigo: string): string {
  return `${window.location.origin}/?i=${codigo}`;
}
