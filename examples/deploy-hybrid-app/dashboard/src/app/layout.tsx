import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'VCF Infrastructure Asset Tracker',
  description: 'Container-to-VM connectivity demo — Infrastructure Asset Tracker dashboard',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{
        margin: 0,
        padding: 0,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
        backgroundColor: '#0f172a',
        color: '#e2e8f0',
        minHeight: '100vh',
      }}>
        {children}
      </body>
    </html>
  );
}
