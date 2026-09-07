/**
 * Structured-output schema (OpenAPI subset), one page per call.
 */
export const invoiceSchema = {
  type: 'OBJECT',
  properties: {
    invoice_number: { type: 'STRING', nullable: true, description: 'The invoice number printed on THIS page, including on continuation pages.' },
    vendor_name: { type: 'STRING', nullable: true },
    invoice_date: { type: 'STRING', nullable: true, description: 'Printed invoice date as YYYY-MM-DD.' },
    page_label: { type: 'STRING', nullable: true, description: 'Any printed page marker, e.g. "PAGE 2 OF 4".' },
    has_totals_block: { type: 'BOOLEAN', description: 'True only if a final totals block is printed on this page.' },
    line_items: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          item_description: { type: 'STRING', description: 'Full item text, verbatim. Many vendors print the size here.' },
          vendor_item_code: { type: 'STRING', nullable: true, description: "The distributor's ITEM CODE column, not the manufacturer number." },
          vendor_category: { type: 'STRING', nullable: true, description: 'Printed section header this row sits under.' },
          raw_quantity: { type: 'NUMBER', nullable: true },
          raw_uom: { type: 'STRING', nullable: true, description: 'Purchase unit column: CS, EA, LB, KE, etc.' },
          raw_pack: { type: 'STRING', nullable: true, description: 'PACK column verbatim, e.g. "6", "12", "ONLY".' },
          raw_size: { type: 'STRING', nullable: true, description: 'SIZE column verbatim, e.g. ".5GAL", "15#AVG". Null if the vendor has no size column.' },
          raw_unit_price: { type: 'NUMBER', nullable: true },
          line_total: { type: 'NUMBER', nullable: true }
        },
        required: ['item_description','vendor_item_code','vendor_category','raw_quantity','raw_uom','raw_pack','raw_size','raw_unit_price','line_total']
      }
    },
    subtotal: { type: 'NUMBER', nullable: true, description: 'Only if printed on this page.' },
    tax: { type: 'NUMBER', nullable: true, description: 'Only if printed on this page.' },
    grand_total: { type: 'NUMBER', nullable: true, description: 'Only if printed on this page.' }
  },
  required: ['invoice_number','vendor_name','invoice_date','page_label','has_totals_block','line_items','subtotal','tax','grand_total']
};
