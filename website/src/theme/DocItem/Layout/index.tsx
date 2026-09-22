import React from 'react';
import Layout from '@theme-original/DocItem/Layout';
import type LayoutType from '@theme/DocItem/Layout';
import type {WrapperProps} from '@docusaurus/types';
import AiTools from '@site/src/components/AiTools';

type Props = WrapperProps<typeof LayoutType>;

export default function LayoutWrapper(props: Props): React.JSX.Element {
  return (
    <>
      <AiTools />
      <Layout {...props} />
    </>
  );
}
