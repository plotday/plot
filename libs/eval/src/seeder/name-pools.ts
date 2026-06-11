/**
 * Curated pools for the shape-preserving anonymizer (anonymize.ts).
 *
 * Conventions:
 * - Every name matches /^[A-Z][a-z]+$/ (no apostrophes, hyphens, or interior
 *   capitals) so anonymized names always look like "First Last".
 * - Names are drawn from many cultures so anonymized corpora stay diverse.
 * - Org word halves are evocative-but-generic nature/landscape words; the
 *   anonymizer joins one from A and one from B (e.g. "lumenforge.com").
 *   None of the halves are major brand names, and combos are chosen to be
 *   unlikely to collide with well-known companies.
 */

export const FIRST_NAMES = [
  "Amara", "Aiden", "Aisha", "Akira", "Alejandro", "Amir", "Anders", "Anika",
  "Anton", "Aria", "Asha", "Astrid", "Ayodele", "Beatriz", "Bilal", "Bruno",
  "Camila", "Carmen", "Chen", "Chiara", "Dahlia", "Dario", "Davi", "Dimitri",
  "Elena", "Elif", "Emeka", "Emil", "Esme", "Farah", "Felix", "Fiona",
  "Freya", "Gabriel", "Giulia", "Hana", "Hassan", "Hugo", "Ines", "Ingrid",
  "Isla", "Ivan", "Jamal", "Jara", "Jonas", "Jorge", "Julia", "Kai",
  "Kamala", "Kenji", "Kira", "Lars", "Leila", "Leo", "Lina", "Lucas",
  "Luna", "Mateo", "Maya", "Mei", "Milan", "Mina", "Nadia", "Naomi",
  "Nia", "Nico", "Nikolai", "Noor", "Omar", "Paulo", "Priya", "Rafael",
  "Ravi", "Renata", "Rohan", "Rosa", "Sana", "Santiago", "Sasha", "Selma",
  "Simone", "Sofia", "Soren", "Stefan", "Tariq", "Tessa", "Theo", "Tomas",
  "Uma", "Vera", "Viktor", "Wei", "Xenia", "Yara", "Yusuf", "Zara",
  "Zoe", "Idris", "Marisol", "Bjorn",
];

export const LAST_NAMES = [
  "Abara", "Adeyemi", "Almeida", "Alvarez", "Andersson", "Aoki", "Baptiste",
  "Barros", "Bergman", "Bianchi", "Brandt", "Calloway", "Castillo",
  "Chowdhury", "Costa", "Dahl", "Delgado", "Devlin", "Dubois", "Endo",
  "Farrow", "Ferreira", "Fischer", "Fontaine", "Fujita", "Gallagher",
  "Garza", "Grimaldi", "Haddad", "Hale", "Hansen", "Harlow", "Hayashi",
  "Holloway", "Ibarra", "Iqbal", "Ivanov", "Jansen", "Kapoor", "Karim",
  "Keller", "Banerjee", "Kimura", "Kowalski", "Krishnan", "Laurent",
  "Lindqvist", "Lobo", "Maddox", "Marchetti", "Mendes", "Mercer", "Moreau",
  "Moretti", "Nakamura", "Navarro", "Nguyen", "Novak", "Okafor", "Okonkwo",
  "Olsen", "Onyango", "Ortega", "Osei", "Pavlov", "Pellegrini", "Petrov",
  "Quinn", "Ramos", "Rasmussen", "Reyes", "Riedel", "Rocha", "Romero",
  "Rossi", "Sato", "Schneider", "Serrano", "Silva", "Singh", "Sokolov",
  "Soto", "Suzuki", "Takahashi", "Tanaka", "Thorne", "Ueda", "Valdez",
  "Varga", "Vasquez", "Vogel", "Walsh", "Weber", "Whitfield", "Yamamoto",
  "Yilmaz", "Zhang", "Zielinski", "Mehta", "Diallo", "Larsen",
];

export const ORG_WORDS_A = [
  "alder", "amber", "arbor", "aspen", "basalt", "beacon", "birch", "briar",
  "cairn", "cedar", "cinder", "cobalt", "coral", "crest", "drift", "dusk",
  "ember", "fern", "flint", "gale", "glen", "harbor", "hazel", "heron",
  "juniper", "kestrel", "lark", "lichen", "lumen", "marsh", "meadow", "moss",
  "north", "onyx", "opal", "pebble", "pine", "quartz", "sable", "tundra",
];

export const ORG_WORDS_B = [
  "bay", "bend", "bloom", "bridge", "brook", "cliff", "cove", "creek",
  "dale", "fall", "field", "ford", "forge", "gate", "grove", "haven",
  "hill", "hollow", "lake", "ledge", "loft", "mill", "peak", "point",
  "port", "reach", "ridge", "shore", "spring", "stead", "stone", "summit",
  "trail", "vale", "view", "ward", "weave", "wharf", "works", "yard",
];
