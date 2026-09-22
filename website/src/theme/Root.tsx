import React from 'react';
import {Analytics} from '@vercel/analytics/react';

type Props = {
  children: React.ReactNode;
};

export default function Root({children}: Props): React.JSX.Element {
  return (
    <>
      {children}
      <Analytics />
    </>
  );
}
