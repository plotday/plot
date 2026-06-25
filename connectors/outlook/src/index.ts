export { default, Outlook } from "./outlook";
// Re-export scopes, products metadata, and scaffolding helpers.
export { OUTLOOK_SCOPES, OPTIONAL_SCOPE_GROUPS, PRODUCTS, type ProductInfo } from "./scopes";
export { PRODUCTS_BY_KEY, type Product } from "./products/product";
export { mailProduct } from "./products/mail";
export { calendarProduct } from "./products/calendar";
export { contactsProduct, CONTACTS_SCOPES } from "./products/contacts";
export { namespace, parse, productKeyOf } from "./product-channel";
export { computeProductStatus, type ProductStatus, type ProductStatusReason, type ProductStatusInputs } from "./product-status";
export { composeChannels, resolveProductForChannelId, resolveProductForLinkType } from "./compose";
