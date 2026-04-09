import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'VCF 9 Knative FaaS + DBaaS Dashboard',
  description: 'Knative Serving serverless audit function — AWS Lambda equivalent on VCF',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{
        margin: 0,
        padding: 0,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
        backgroundColor: '#0d1117',
        color: '#e2e8f0',
        minHeight: '100vh',
      }}>
        {children}
      </body>
    </html>
  );
}
